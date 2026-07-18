# frozen_string_literal: true

require "securerandom"
require "json"
require "time"

module Rubino
  module Memory
    module Backends
      # Bi-temporal fact store on embedded SQLite with hybrid recall — minus a
      # graph DB, a server, or a multi-LLM-call pipeline.
      #
      # Facts are WRITTEN by the agent-callable memory tool and by the post-turn
      # background review fork (BackgroundReviewJob), the single extraction path;
      # this backend owns storage + recall, not a per-turn aux-LLM extractor.
      #
      # Three ideas drive the design:
      #   * ATOMIC facts — one declarative fact per row.
      #   * BI-TEMPORAL supersession — a contradicted fact is soft-retired
      #     (valid_to set), not deleted; "live" memory = valid_to IS NULL, so we
      #     get temporal correctness without losing provenance.
      #   * HYBRID ranked recall — FTS5/BM25 (+ optional vector KNN) fused with
      #     Reciprocal Rank Fusion and lightly kind-weighted, top-k under the
      #     char budget. Graph (1-hop) and recency are tail SUPPLEMENTS that only
      #     backfill the budget after direct content matches — never outranking
      #     them. (Optional vector KNN via sqlite-vec when available; see #vector?.)
      #
      # The injection-defense floor (ThreatScanner + char-budget) is enforced on
      # the write path exactly as Memory::Store does, so no fact can splice
      # tainted or over-budget content into a future system prompt.
      class Sqlite < Backend
        include SqliteGraph

        TABLE = :memory_facts
        FTS   = :memory_facts_fts
        RRF_K = 60
        DEFAULT_K = 20

        # Weighted-RRF list weights for the DIRECT relevance signals (FTS/BM25 and
        # vector KNN). Graph (1-hop) and recency are no longer fused here — they
        # are tail supplements (see #rank) so they can never outrank a direct
        # content match.
        FTS_WEIGHT    = 3.0
        VECTOR_WEIGHT = 3.0

        # Trivial words that appear in almost every fact ("user", "project") or
        # carry no retrieval signal — excluded from the FTS MATCH so a probe
        # like "what package manager does the user use" doesn't match every
        # "User ..." fact on the word "user".
        STOPWORDS = %w[
          the a an of to in on at for and or is are was were be been being do does did
          how what where when which who whom whose why this that these those it its
          use uses used user users project projects right now
        ].to_set.freeze

        # Maps the backend's fact `kind` onto Memory::Store's budget group so a
        # user_profile fact is metered against the user budget and everything
        # else against the shared memory budget — same split as the default
        # backend.
        USER_KIND = "user_profile"

        # Light kind weighting applied after RRF so durable user facts outrank
        # one-off facts on ties.
        KIND_WEIGHT = Hash.new(1.0).merge(
          "user_profile" => 1.3,
          "preference" => 1.2,
          "env" => 1.1
        ).freeze

        def self.backend_name
          "sqlite"
        end

        def initialize(config: nil, db: nil)
          super(config: config)
          @db = db || Rubino.database.db
        end

        # FTS5 ships with the sqlite3 gem, so the backend is always available.
        # (Vector mode is a best-effort upgrade gated separately by #vector?.)
        def available?
          true
        end

        # -- WRITE path --

        def store(kind:, content:, source_session_id: nil, confidence: 1.0, metadata: {})
          k = normalize_kind(kind)
          # Exact/normalized-verbatim dedup at the direct write seam (#Y4):
          # MemoryTool#add bypasses the extraction near-dup gate, so the same fact
          # saved twice used to mint two identical rows. Idempotent — a verbatim
          # repeat (or whitespace/case variant) returns the existing row.
          existing = verbatim_duplicate(k, content)
          if existing
            record_fact_saved(k, inserted: false)
            return present(existing)
          end

          result = insert_fact(
            text: content,
            kind: k,
            entities: graph_entities(content, metadata[:entities]),
            source_session_id: source_session_id,
            confidence: confidence,
            valid_from: metadata[:valid_from]
          )
          record_fact_saved(k, inserted: true)
          result
        end

        # Replace the first LIVE fact of `kind` whose text includes `old_text`.
        # Modelled as a supersession so history is preserved.
        def replace(kind:, old_text:, content:)
          target = live_dataset.where(kind: normalize_kind(kind))
                               .where(Sequel.like(:text, "%#{old_text}%")).first
          return nil unless target

          # Retire first so the old row's chars free up before the new fact is
          # budget-checked (a same-size replace must always fit).
          new_id = SecureRandom.uuid
          retire!(target[:id], new_id)
          insert_fact(text: content, kind: target[:kind],
                      entities: parse_entities(target[:entities_json]),
                      source_session_id: target[:source_session_id], id: new_id)
          target
        end

        # Hard-delete the first LIVE fact of `kind` whose text includes
        # `old_text` (forget = remove from the record entirely, vs supersede).
        def forget(kind:, old_text:)
          target = live_dataset.where(kind: normalize_kind(kind))
                               .where(Sequel.like(:text, "%#{old_text}%")).first
          return nil unless target

          @db[TABLE].where(id: target[:id]).delete
          target
        end

        # -- READ path --

        def user_profile
          return nil unless @config.dig("memory", "user_profile_enabled")

          rows = live_dataset.where(kind: USER_KIND).order(Sequel.desc(:created_at)).all
          return nil if rows.empty?

          text = rows.map { |r| r[:text] }.join("\n")
          limit = @config.dig("memory", "user_char_limit")
          text.length > limit ? text[0...limit] : text
        end

        def project_context
          return nil unless @config.dig("memory", "project_context_enabled")

          rows = live_dataset.where(kind: %w[project env]).order(Sequel.desc(:created_at)).limit(10).all
          return nil if rows.empty?

          rows.map { |r| r[:text] }.join("\n")
        end

        # HYBRID recall over LIVE facts: FTS5/BM25 on `query` (and vector KNN when
        # available) fused via RRF and kind-weighted as the direct relevance
        # ranking, then graph/recency-supplemented and greedily packed under the
        # memory char budget. Returns rows shaped like the default backend
        # ({id:, kind:, content:, ...}) so the prompt assembler is unchanged.
        def retrieve(session_id:, query: nil, k: DEFAULT_K)
          ranked = rank(query: query, k: k)
          budget = @config.dig("memory", "memory_char_limit")
          selected = []
          injected_ids = []
          total = 0
          cut = false
          ranked.each do |row|
            len = row[:text].to_s.length
            # Greedy prefix pack: once one candidate would blow the injection
            # budget, none after it are injected either (unchanged behaviour) —
            # but we keep iterating so the DROPPED tail is still recorded for the
            # explain trace ("retrieved but budget-dropped").
            cut ||= budget&.positive? && total + len > budget
            next if cut

            selected << present(row)
            injected_ids << row[:id]
            total += len
          end
          record_retrieval_explain(ranked, injected_ids) if Telemetry.enabled?
          selected
        end

        # Explainability side-channel for the last #retrieve: the recall span
        # (Lifecycle#load_memory) reads this to expose WHY each fact was (or was
        # not) recalled — per-candidate score/source/injected plus the aggregate
        # signal hit-counts. nil until a retrieve runs under otel; never consumed
        # by the prompt path, so retrieval behaviour is unchanged.
        attr_reader :last_retrieval

        # -- admin --

        # LIVE facts only by default — a superseded fact is a tombstone, not a
        # current memory, so listing it undecorated next to its replacement
        # presents contradicted data as true and makes the rows disagree with
        # #count/#retrieve (#82). `include_retired: true` opts into the full
        # supersession history (`rubino memory list --all`).
        def list(kind: nil, limit: 20, include_retired: false)
          ds = (include_retired ? @db[TABLE] : live_dataset).order(Sequel.desc(:created_at)).limit(limit)
          ds = ds.where(kind: normalize_kind(kind)) if kind
          ds.all.map { |r| present(r) }
        end

        def find(id)
          row = resolve_row(id)
          row && present(row)
        end

        def delete(id)
          row = resolve_row(id)
          row ? @db[TABLE].where(id: row[:id]).delete.positive? : false
        end

        # Resolve a caller-supplied id to AT MOST ONE row (shared with Store,
        # parameterized by this backend's dataset).
        def resolve_row(id)
          Memory.resolve_row(@db[TABLE], id)
        end

        # Count only LIVE facts (valid_to IS NULL) — retired/superseded rows are
        # tombstones the admin surface and #list already hide.
        def count
          live_dataset.count
        end

        private

        # ---- ranking ----

        def rank(query:, k:)
          # DIRECT relevance first: FTS/BM25 (+ vector KNN when wired) fused by
          # weighted RRF. These are the only signals that match the query's
          # CONTENT, so the fact a keyword probe ranks #1 must stay #1.
          fts_ids = fts_match(query, k * 3)
          vector_ids = vector? && query ? vector_match(query, k * 3) : []

          lists = [[fts_ids, FTS_WEIGHT]]
          lists << [vector_ids, VECTOR_WEIGHT] if vector? && query

          scores = Hash.new(0.0)
          lists.each do |ids, weight|
            ids.each_with_index { |id, idx| scores[id] += weight / (RRF_K + idx + 1) }
          end

          rows = live_dataset.where(id: scores.keys).all.each_with_object({}) { |r, h| h[r[:id]] = r }
          ranked = scores.keys
                         .map { |id| rows[id] }
                         .compact
                         .sort_by { |row| -(scores[row[:id]] * KIND_WEIGHT[row[:kind]]) }

          # Graph (1-hop neighbours) and recency are TAIL SUPPLEMENTS, not
          # co-equal RRF lists. Fusing them into the score let a dense entity hub
          # (e.g. every "Melanie" fact) or a burst of freshly-ingested but
          # irrelevant facts outscore the right atomic fact that FTS had ranked
          # #1 — the dominant cause of single-shot recall misses on this store.
          # They now only BACKFILL the budget after direct hits: graph first (a
          # connected fact a keyword probe missed), then recency (so a no-match
          # query still surfaces the freshest live facts). Neither can outrank a
          # direct relevance hit.
          backfill_rows, graph_ids, recency_ids = tail_backfill(ranked, k, query)

          # Stash the per-candidate provenance (which signal surfaced each id +
          # its fused score) so #retrieve can hand a fully explainable recall to
          # the telemetry span. Only when otel is on — zero-cost otherwise.
          stash_rank_provenance(scores, fts_ids, vector_ids, graph_ids, recency_ids) if Telemetry.enabled?

          ranked.first(k) + backfill_rows
        end

        # Fill the remaining budget (k − direct hits) with supplementary facts
        # NOT already ranked: 1-hop graph neighbours of the query first, then
        # recency. Returns [rows, graph_ids, recency_ids] — the extra id lists let
        # #rank attribute each backfilled candidate to its signal for telemetry;
        # rows is [] (and the id lists their raw hits) when nothing backfills.
        def tail_backfill(ranked, k, query)
          return [[], [], []] if ranked.size >= k

          have = ranked.map { |r| r[:id] }.to_set
          graph_ids = query && graph? ? graph_neighbors(query, k * 2) : []
          recency_ids = recency(k * 2)
          ids = (graph_ids + recency_ids).reject { |id| have.include?(id) }.uniq.first(k - ranked.size)
          return [[], graph_ids, recency_ids] if ids.empty?

          by_id = live_dataset.where(id: ids).all.each_with_object({}) { |r, h| h[r[:id]] = r }
          [ids.map { |id| by_id[id] }.compact, graph_ids, recency_ids]
        end

        # BM25 ranking over live facts. FTS5's MATCH needs a sanitized query
        # (bare words OR-ed) so user punctuation never raises a syntax error.
        def fts_match(query, limit)
          terms = fts_terms(query)
          return [] if terms.empty?

          @db[FTS]
            .select(Sequel.lit("memory_facts.id").as(:id))
            .join(Sequel.lit("memory_facts"), Sequel.lit("memory_facts.rowid = memory_facts_fts.rowid"))
            .where(Sequel.lit("memory_facts_fts MATCH ?", terms))
            .where(Sequel.lit("memory_facts.valid_to IS NULL"))
            .order(Sequel.lit("bm25(memory_facts_fts)"))
            .limit(limit)
            .all
            .map { |r| r[:id] }
        rescue Sequel::DatabaseError
          []
        end

        def recency(limit)
          live_dataset.order(Sequel.desc(:created_at)).limit(limit).select_map(:id)
        end

        # Best-effort vector KNN — only when sqlite-vec is wired (see #vector?).
        # Kept tiny: cosine over an in-Ruby decode of the embedding blobs.
        def vector_match(query, limit)
          qvec = embed(query)
          return [] unless qvec

          live_dataset.exclude(embedding: nil).all.map do |row|
            vec = decode_embedding(row[:embedding])
            vec ? [row[:id], cosine(qvec, vec)] : nil
          end.compact.sort_by { |(_, sim)| -sim }.first(limit).map(&:first)
        rescue StandardError
          []
        end

        def fts_terms(query)
          return "" if query.nil?

          words = query.to_s.downcase.scan(/[\p{L}\p{N}]+/)
                       .reject { |w| w.length < 2 || STOPWORDS.include?(w) }.uniq
          # If the query was all stopwords, fall back to the bare tokens so we
          # still attempt a match rather than returning nothing.
          words = query.to_s.downcase.scan(/[\p{L}\p{N}]+/).uniq if words.empty?
          words.first(12).map { |w| "\"#{w}\"" }.join(" OR ")
        end

        # ---- low-level fact ops ----

        def insert_fact(text:, kind:, entities: [], source_session_id: nil,
                        confidence: 1.0, valid_from: nil, id: nil, edges: [])
          enforce_guards!(kind, text)
          now = Time.now.utc.iso8601
          id ||= SecureRandom.uuid

          @db[TABLE].insert(
            id: id,
            text: text,
            kind: kind,
            entities_json: entities.empty? ? nil : JSON.generate(entities),
            source_session_id: source_session_id,
            confidence: confidence,
            valid_from: (valid_from.to_s.empty? ? now : valid_from),
            valid_to: nil,
            superseded_by: nil,
            embedding: (emb = maybe_embed(text)) && Sequel.blob(emb),
            created_at: now,
            updated_at: now
          )
          # Graph-lite: upsert entity nodes + co-occurrence/typed edges for this
          # fact. Best-effort — a graph hiccup must never abort the fact write.
          # Wrapped so the graph feed is TELEMETRISED (entities/edges added +
          # running totals) on the `memory.graph_indexed` span when otel is on.
          record_graph_indexed(id, entities, edges) unless entities.empty? && Array(edges).empty?
          present(@db[TABLE].where(id: id).first)
        rescue Sequel::DatabaseError, StandardError => e
          raise if @db[TABLE].where(id: id).first.nil? # fact insert itself failed: surface it

          log_skip(e) # fact stored, only graph indexing tripped
          present(@db[TABLE].where(id: id).first)
        end

        def retire!(old_id, new_id)
          @db[TABLE].where(id: old_id).update(
            valid_to: Time.now.utc.iso8601,
            superseded_by: new_id,
            updated_at: Time.now.utc.iso8601
          )
        end

        def live_dataset
          @db[TABLE].where(valid_to: nil)
        end

        # First LIVE fact of `kind` whose normalized-verbatim form equals the
        # candidate's (trim/collapse-whitespace + case-fold, #Y4), or nil.
        def verbatim_duplicate(kind, content)
          target = Deduplicator.normalize_verbatim(content)
          return nil if target.empty?

          live_dataset.where(kind: kind).all
                      .find { |row| Deduplicator.normalize_verbatim(row[:text]) == target }
        end

        # ---- guards (ThreatScanner + char-budget, same floor as Store) ----

        def enforce_guards!(kind, text)
          threat = ThreatScanner.scan(text)
          raise Store::ThreatDetectedError, threat if threat

          enforce_char_budget!(kind, text)
        end

        def enforce_char_budget!(kind, text)
          group = kind == USER_KIND ? "user" : "memory"
          # INGEST cap, decoupled from the injection budget. memory.memory_char_limit
          # bounds only what `retrieve` packs into the prompt; storing facts is
          # gated by memory.ingest_char_limit (nil => unbounded) so long
          # multi-session conversations don't stall once the injection budget
          # fills. User facts keep their own (small) profile budget.
          key = group == "user" ? "user_char_limit" : "ingest_char_limit"
          limit = @config.dig("memory", key)
          return unless limit&.positive?

          Memory.enforce_budget!(group: group, limit: limit,
                                 current: current_chars(group),
                                 requested: text.to_s.length)
        end

        # Budget is metered over LIVE facts only — superseded rows don't count
        # against the injection budget since they're never injected.
        def current_chars(group)
          ds = live_dataset
          ds = group == "user" ? ds.where(kind: USER_KIND) : ds.exclude(kind: USER_KIND)
          ds.sum(Sequel.function(:length, :text)).to_i
        end

        # ---- embeddings (best-effort) ----

        # Vector mode is opt-in (`memory.sqlite.vector: true`). Off by default →
        # FTS5-only hybrid. No embed call is EVER made unless the user sets
        # vector:true. When vector:true, embeddings are routed through the
        # configurable `auxiliary.embedding` endpoint (local-first, no paid API);
        # at its defaults (provider:"main", model:"") it falls back to the
        # global RubyLLM.embed.
        def vector?
          return @vector unless @vector.nil?

          @vector = @config.dig("memory", "sqlite", "vector") == true
        end

        # Graph-lite 1-hop blend is ON by default; `memory.sqlite.graph: false`
        # disables it (FTS-only recall) — used to A/B the graph signal.
        def graph?
          return @graph unless @graph.nil?

          @graph = @config.dig("memory", "sqlite", "graph") != false
        end

        # Entity names to index into the co_occurs graph for a fact, per
        # memory.sqlite.graph_extraction:
        #   "deterministic" (default) → caller-supplied ∪ a pure-Ruby heuristic
        #        over the fact text (option 1 — feeds the graph for free, no LLM)
        #   "supplied" → only caller-supplied entities (option 2 — the memory
        #        tool's `entities` param, filled by the model; no heuristic)
        #   "off" → none (graph stays empty; bring-your-own / disable)
        # Always [] when the graph blend itself is disabled (graph:false), so a
        # supplied-entities call can't secretly repopulate a disabled graph.
        def graph_entities(text, supplied)
          return [] unless graph?

          supplied = Array(supplied).map { |e| e.to_s.strip }.reject(&:empty?)
          case graph_extraction
          when "off"      then []
          when "supplied" then supplied.uniq { |e| e.downcase }
          else # "deterministic" (default) and any unrecognised value
            (supplied + Rubino::Memory::EntityExtractor.extract(text)).uniq { |e| e.downcase }
          end
        end

        def graph_extraction
          @graph_extraction ||=
            (@config.dig("memory", "sqlite", "graph_extraction") || "deterministic").to_s
        end

        def maybe_embed(text)
          return nil unless vector?

          vec = embed(text)
          vec && encode_embedding(vec)
        end

        def embed(text)
          return nil unless vector?

          cfg = embedding_config
          res = if embedding_configured?(cfg)
                  scoped_embed(text, cfg)
                else
                  RubyLLM.embed(text.to_s)
                end
          res.respond_to?(:vectors) ? res.vectors : res
        rescue StandardError
          nil
        end

        # -- aux embedding resolution --

        def embedding_config
          cfg = @config.auxiliary_config("embedding") || {}
          return cfg unless cfg.is_a?(Hash) && !cfg.empty?

          cfg
        end

        def embedding_configured?(cfg)
          return false unless cfg.is_a?(Hash)

          provider = cfg["provider"].to_s.strip
          model    = cfg["model"].to_s.strip
          !(provider.empty? || provider == "main") || !model.empty?
        end

        def scoped_embed(text, cfg)
          resolved_provider = resolve_embedding_provider(cfg)
          model = cfg["model"].to_s.strip
          base_url = cfg["base_url"].to_s.strip

          llm_config = RubyLLM::Configuration.new
          # Copy API keys from the global RubyLLM config so the scoped
          # context inherits the process's credentials (ENV vars).
          copy_llm_api_keys(llm_config)
          # Point the resolved provider at the configured base URL.
          set_provider_base_url(llm_config, resolved_provider, base_url) unless base_url.empty?
          # Honour the configured model (or keep the global default).
          llm_config.default_embedding_model = model unless model.empty?

          # A local/custom embedding model (the advertised local-first use case)
          # is NOT in RubyLLM's static registry, so a bare embed raises
          # ModelNotFoundError and vector recall silently falls back to FTS-only.
          # When the user explicitly names a model + provider, tell RubyLLM to
          # trust it — mirroring the provider's `assume_model_exists` for the main
          # model. Without a model we keep the registry-validated default path.
          opts = { context: RubyLLM::Context.new(llm_config) }
          opts.merge!(model: model, provider: resolved_provider.to_sym, assume_model_exists: true) unless model.empty?
          RubyLLM.embed(text.to_s, **opts)
        end

        def resolve_embedding_provider(cfg)
          provider = cfg["provider"].to_s.strip
          return @config.dig("model", "provider").to_s if provider.empty? || provider == "main"

          provider
        end

        # Copy known API keys from the global RubyLLM config to a scoped one
        # so embedding calls to a custom endpoint still carry credentials.
        def copy_llm_api_keys(target)
          %w[openai_api_key anthropic_api_key gemini_api_key deepseek_api_key
             ollama_api_key bedrock_api_key bedrock_secret_key].each do |key|
            val = RubyLLM.config.public_send(key)
            target.public_send("#{key}=", val) if val
          rescue NoMethodError
            # Provider option not registered — ignore
          end
        end

        def set_provider_base_url(target, provider_name, base_url)
          key = "#{provider_name}_api_base"
          target.public_send("#{key}=", base_url) if target.respond_to?("#{key}=")
        rescue NoMethodError
          # Provider doesn't support base_url — ignore
        end

        def encode_embedding(vec) = vec.pack("e*")

        def decode_embedding(blob) = blob && blob.to_s.unpack("e*")

        def cosine(a, b)
          return 0.0 if a.empty? || b.empty? || a.size != b.size

          dot = a.zip(b).sum { |x, y| x * y }
          na = Math.sqrt(a.sum { |x| x * x })
          nb = Math.sqrt(b.sum { |x| x * x })
          na.zero? || nb.zero? ? 0.0 : dot / (na * nb)
        end

        # ---- helpers ----

        def normalize_kind(kind)
          k = kind.to_s
          return USER_KIND if k.empty?

          # Map legacy/default-backend kinds onto the fact-store vocabulary so the
          # backend tolerates store() calls from the existing MemoryTool/job.
          case k
          when "user_profile", "preference", "fact", "env" then k
          when "project_context", "project"                then "project"
          when "technical_decision"                        then "fact"
          when "task_state", "tool_result"                 then "fact"
          else k
          end
        end

        def parse_entities(json)
          json ? JSON.parse(json) : []
        rescue JSON::ParserError
          []
        end

        # Shape a row like the default backend's memories row so downstream
        # (PromptAssembler, CLI) sees the same {id:, kind:, content:} contract.
        def present(row)
          {
            id: row[:id],
            kind: row[:kind],
            content: row[:text],
            confidence: row[:confidence],
            source_session_id: row[:source_session_id],
            entities: parse_entities(row[:entities_json]),
            valid_from: row[:valid_from],
            valid_to: row[:valid_to],
            superseded_by: row[:superseded_by],
            created_at: row[:created_at]
          }
        end

        def log_skip(error)
          Rubino.logger.warn(event: "memory.sqlite.skip", error: error.class.name)
        rescue StandardError
          # logging must never block the write/extract path
        end

        # ---- telemetry (best-effort, no-op unless otel.enabled) ----

        # Record which signal(s) surfaced each candidate id and its fused RRF
        # score, captured by #rank for the current retrieval. A candidate can
        # carry several sources (e.g. fts + vector); graph/recency are the tail
        # backfill signals. Kept per-id so #record_retrieval_explain can join it
        # against the ordered/budget-cut result. Never raises.
        def stash_rank_provenance(scores, fts_ids, vector_ids, graph_ids, recency_ids)
          sources = Hash.new { |h, id| h[id] = [] }
          fts_ids.each { |id| sources[id] << "fts" }
          vector_ids.each { |id| sources[id] << "vector" }
          graph_ids.each { |id| sources[id] << "graph" }
          recency_ids.each { |id| sources[id] << "recency" }
          @rank_provenance = {
            scores: scores, sources: sources,
            fts_hits: fts_ids.size, vector_hits: vector_ids.size,
            graph_hits: graph_ids.size, recency_hits: recency_ids.size
          }
        rescue StandardError
          @rank_provenance = nil
        end

        # Build the explainable retrieval record consumed by the recall span:
        # aggregate signal hit-counts (always-on, pure counts) plus a per-
        # candidate list — score, source signals, and whether each fact was
        # INJECTED into the prompt or retrieved-but-budget-dropped. Candidate
        # CONTENT rides here too; the span gates its export on capture_content.
        def record_retrieval_explain(ranked, injected_ids)
          prov = @rank_provenance || {}
          scores = prov[:scores] || {}
          sources = prov[:sources] || {}
          injected = injected_ids.to_set
          candidates = ranked.map do |row|
            id = row[:id]
            { id: id, kind: row[:kind], content: row[:text],
              score: (scores[id] * KIND_WEIGHT[row[:kind]]).round(6),
              sources: sources[id] || [], injected: injected.include?(id) }
          end
          @last_retrieval = {
            vector_enabled: vector?,
            fts_hits: prov[:fts_hits].to_i, vector_hits: prov[:vector_hits].to_i,
            graph_hits: prov[:graph_hits].to_i, recency_hits: prov[:recency_hits].to_i,
            retrieved_count: ranked.size, injected_count: injected_ids.size,
            candidates: candidates
          }
        rescue StandardError
          @last_retrieval = nil
        end

        # Save-decision telemetry for one persisted fact, riding the proven OTLP
        # trace pipeline (Telemetry.span). A short `memory.fact_saved` span
        # carries the fact kind, whether this was a NEW insert or a verbatim
        # dedup hit, and the running live-fact count — enough for a dashboard to
        # chart saves-by-kind and store growth. Guarded on enabled? so the extra
        # #count query never runs when telemetry is off; never raises.
        def record_fact_saved(kind, inserted:)
          return unless Telemetry.enabled?

          Telemetry.span("memory.fact_saved",
                         attributes: { "rubino.memory.fact.kind" => kind.to_s,
                                       "rubino.memory.fact.inserted" => inserted,
                                       "rubino.memory.facts.count" => count }) { nil }
        rescue StandardError
          nil
        end

        # Run the graph index for a fact and, when telemetry is on, emit a
        # `memory.graph_indexed` span with the nodes/edges ADDED by this fact (a
        # before/after diff, since index_fact_graph resolves-or-creates) plus the
        # graph's running totals. index_fact_graph ALWAYS runs and its own errors
        # still propagate to insert_fact's guard — only the telemetry counting is
        # swallowed, so a metrics hiccup can't drop the graph feed.
        def record_graph_indexed(fact_id, entities, edges)
          unless Telemetry.enabled?
            index_fact_graph(fact_id, entities, typed: edges)
            return
          end

          before_entities = graph_entity_count
          before_edges = graph_edge_count
          index_fact_graph(fact_id, entities, typed: edges)
          emit_graph_span(before_entities, before_edges)
        end

        def emit_graph_span(before_entities, before_edges)
          after_entities = graph_entity_count
          after_edges = graph_edge_count
          Telemetry.span("memory.graph_indexed",
                         attributes: {
                           "rubino.memory.graph.entities_added" => after_entities - before_entities,
                           "rubino.memory.graph.edges_added" => after_edges - before_edges,
                           "rubino.memory.graph.entities_total" => after_entities,
                           "rubino.memory.graph.edges_total" => after_edges
                         }) { nil }
        rescue StandardError
          nil
        end
      end
    end
  end
end
