# frozen_string_literal: true

require "securerandom"
require "time"

module Rubino
  module Memory
    # Graph-lite layer for the Sqlite backend (Memory Phase 3b).
    #
    # A thin mixin over two tables (memory_entities + memory_edges) that turns
    # the per-fact entity tags into a tiny knowledge graph and blends a bounded
    # 1-hop traversal into retrieval. NOT a graph DB — just entity resolution by
    # normalized name and a bounded join over edges.
    #
    # Edges are populated two ways, both cheap (no extra LLM call beyond the
    # single extraction call the backend already makes):
    #   * DETERMINISTIC co-occurrence — every pair of entities tagged on the
    #     same fact gets a `co_occurs` edge (free, derived from `entities_json`).
    #   * TYPED relations — the extraction LLM optionally returns `edges:
    #     [{src, relation, dst}]` in the SAME structured call, so the typed
    #     graph costs 0 additional calls/turn.
    #
    # Edges are bi-temporal like facts: a contradicting relation soft-retires
    # the old edge (valid_to set), it is not deleted.
    module SqliteGraph
      ENTITIES = :memory_entities
      EDGES    = :memory_edges
      CO_OCCURS = "co_occurs"

      # ---- node resolution ----

      # Resolve (find-or-create) an entity node by normalized name, returning
      # its id. Same name from different facts collapses to one node.
      def resolve_entity(name, kind: nil)
        norm = normalize_entity_name(name)
        return nil if norm.empty?

        existing = @db[ENTITIES].where(name_norm: norm).first
        return existing[:id] if existing

        now = Time.now.utc.iso8601
        id = SecureRandom.uuid
        @db[ENTITIES].insert(
          id: id, name: name.to_s.strip, name_norm: norm, kind: kind,
          created_at: now, updated_at: now
        )
        id
      rescue Sequel::UniqueConstraintViolation
        # Concurrent insert: re-read the winner.
        @db[ENTITIES].where(name_norm: norm).get(:id)
      end

      def normalize_entity_name(name)
        name.to_s.strip.downcase.gsub(/\s+/, " ")
      end

      # ---- edge population ----

      # Wire the graph for a freshly-inserted fact: upsert its entity nodes,
      # connect every co-occurring pair with a co_occurs edge, and add any
      # typed relations the extractor emitted for this fact. Bounded and free
      # of extra LLM calls. `typed` is an array of {src, relation, dst} hashes.
      def index_fact_graph(fact_id, entities, typed: [])
        ids = Array(entities).filter_map { |e| resolve_entity(e) }.uniq
        ids.combination(2).each { |a, b| upsert_edge(a, b, CO_OCCURS, fact_id) }

        Array(typed).each do |edge|
          src = resolve_entity(edge["src"] || edge[:src])
          dst = resolve_entity(edge["dst"] || edge[:dst])
          rel = (edge["relation"] || edge[:relation]).to_s.strip.downcase
          next if src.nil? || dst.nil? || src == dst || rel.empty?

          # A changed typed relation between the SAME pair supersedes the old
          # one (e.g. "uses postgres" -> "uses sqlite" is handled at the fact
          # level; here we keep the latest relation label live).
          supersede_edge(src, dst, rel)
          upsert_edge(src, dst, rel, fact_id)
        end
      end

      # Insert a live edge unless an identical live edge already exists
      # (idempotent). Co_occurs edges are undirected in effect: we store the
      # canonical ordering for the pair so the de-dup works both ways.
      def upsert_edge(src, dst, relation, source_fact_id)
        a, b = (relation == CO_OCCURS) ? [src, dst].minmax : [src, dst]
        return if @db[EDGES].where(
          src_entity_id: a, dst_entity_id: b, relation: relation, valid_to: nil
        ).count.positive?

        now = Time.now.utc.iso8601
        @db[EDGES].insert(
          id: SecureRandom.uuid, src_entity_id: a, dst_entity_id: b,
          relation: relation, source_fact_id: source_fact_id,
          valid_from: now, valid_to: nil, superseded_by: nil,
          created_at: now, updated_at: now
        )
      end

      # Soft-retire any live typed edge between src->dst whose relation differs,
      # so a contradicting relation supersedes the old one (history kept).
      def supersede_edge(src, dst, _relation)
        @db[EDGES].where(src_entity_id: src, dst_entity_id: dst, valid_to: nil)
                  .exclude(relation: CO_OCCURS)
                  .update(valid_to: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601)
      end

      # ---- 1-hop traversal ----

      # Given query text, find seed entities whose name appears in the query,
      # walk LIVE edges out one hop to neighbor entities, and return the ids of
      # LIVE facts tagged with any seed-or-neighbor entity. This surfaces facts
      # connected through a relation that pure FTS on the probe would miss.
      # Bounded: capped seeds, single hop, capped fact scan.
      def graph_neighbors(query, limit)
        seeds = seed_entities(query)
        return [] if seeds.empty?

        # 1-hop: neighbors reachable via a live edge in either direction.
        neighbor_ids = @db[EDGES]
                       .where(valid_to: nil)
                       .where(Sequel.|({ src_entity_id: seeds }, { dst_entity_id: seeds }))
                       .select_map(%i[src_entity_id dst_entity_id])
                       .flatten.uniq

        entity_ids = (seeds + neighbor_ids).uniq
        return [] if entity_ids.empty?

        names = @db[ENTITIES].where(id: entity_ids).select_map(:name_norm)
        facts_tagged_with(names, limit)
      end

      # Entities whose normalized name (or a token of it) appears in the query.
      def seed_entities(query)
        tokens = query.to_s.downcase.scan(/[\p{L}\p{N}]+/).reject { |w| w.length < 2 }.uniq
        return [] if tokens.empty?

        @db[ENTITIES].where(name_norm: tokens).select_map(:id).first(8)
      end

      # Live fact ids whose entities_json contains any of the given normalized
      # entity names. Bounded scan over the live set (small in practice).
      def facts_tagged_with(norm_names, limit)
        wanted = norm_names.to_set
        return [] if wanted.empty?

        live_dataset.exclude(entities_json: nil).order(Sequel.desc(:created_at))
                    .limit(limit * 6).all.filter_map do |row|
          ents = parse_entities(row[:entities_json]).map { |e| e.to_s.downcase }
          row[:id] if ents.any? { |e| wanted.include?(e) }
        end.first(limit)
      end
    end
  end
end
