# frozen_string_literal: true

require "ruby_llm"

module Rubino
  module Context
    # Assembles the complete prompt from all context sources.
    # Returns the message array (system + summary + history) for LLM submission.
    class PromptAssembler
      # Process-wide cache of the memory snapshot keyed by session id.
      # Captured the first time build_system_prompt runs for a session and
      # reused on every subsequent assembly in that session — even if the
      # agent calls Tools::MemoryTool mid-session. Rationale: without
      # freezing, an injected memory written this turn would land in the
      # *next* prompt and effectively self-elevate. The agent must wait
      # for the next session (or call reset_snapshot!) for new writes to
      # appear in the system prompt.
      @snapshots = {}
      @snapshots_mutex = Mutex.new

      class << self
        # Returns the cached snapshot for a session, computing it via the
        # supplied block on first access. The block receives no args and
        # must return the memory-context hash to freeze.
        def snapshot_for(session_id)
          @snapshots_mutex.synchronize do
            @snapshots[session_id] ||= yield
          end
        end

        # Drops the cached snapshot for a session so the next assembly
        # captures fresh memory state. Use this when a tool call must
        # influence the very next turn (trade-off: the freeze stops
        # protecting against same-turn poisoning).
        def reset_snapshot!(session_id)
          @snapshots_mutex.synchronize { @snapshots.delete(session_id) }
        end

        # Test/teardown hook. Not part of the public API.
        def reset_all_snapshots!
          @snapshots_mutex.synchronize { @snapshots.clear }
        end
      end

      def initialize(session:, memory_context:, config:, agent_definition: nil,
                     ignore_rules: false)
        @session = session
        @memory_context = memory_context
        @config = config
        @agent_definition = agent_definition
        # --ignore-rules suppresses project-context discovery
        # (AGENTS.md/CLAUDE.md/.rubino.md/.cursorrules). The flag is threaded
        # from Lifecycle so the CLI option genuinely skips discovery (#47), not
        # just the trust gate.
        @ignore_rules = ignore_rules
        @message_store = Session::Store.new
      end

      # Builds and returns the full message array for LLM submission
      def build
        messages = []

        # Single system message. The content is split into a STABLE PREFIX
        # (identity / product / env / user-profile snapshot / skills / project
        # context) and a VOLATILE TAIL (freshly-retrieved relevant-memories +
        # the post-compaction session-summary). The prefix carries the prompt-
        # cache breakpoint (#311); the tail — which can change turn-to-turn —
        # sits AFTER it so the cached bytes stay byte-stable. Both regions live
        # in ONE role:"system" entry (#253), built as a Content::Raw array of
        # text blocks when caching is on, or a plain joined String otherwise.
        messages << { role: "system", content: system_content }

        # Conversation history. Repair tool pairing across the FULL list before
        # mapping to wire format — this is the defensive "net" that recovers
        # sessions already corrupted by the historical metadata-dropping bug in
        # compaction/fork (those rows exist in prod). Mirrors Claude Code's
        # pre-call sanitization: never emit an orphan tool block that 400s a
        # strict provider. Conservative by design — when in doubt, keep.
        history = repair_tool_pairs(@message_store.for_session(@session[:id]))
        history.each do |msg|
          messages << msg.to_context
        end

        messages
      end

      private

      # Final pairing repair over the full history (a list of Message objects).
      # Two orphan shapes 400 strict providers; we fix both, conservatively:
      #
      #   1. tool RESULT with no matching assistant tool_call upstream → drop it.
      #   2. assistant tool_call whose results are ENTIRELY absent downstream →
      #      strip its tool_calls (keep the message if it still has content,
      #      otherwise drop it). Partially-answered calls are LEFT ALONE: pruning
      #      a still-referenced id would itself create an orphan.
      #
      # Reuses ToolPairSanitizer's id predicates so the matching logic lives in
      # one place. Returns a list of Message objects safe to map via to_context.
      def repair_tool_pairs(history)
        sanitizer = ToolPairSanitizer.new

        # All tool_call ids declared by assistant messages anywhere in history.
        declared_ids = history
                       .select { |m| sanitizer.assistant_tool_call?(m) }
                       .flat_map { |m| sanitizer.tool_call_ids(m) }
                       .to_set

        # All ids actually answered by a tool result anywhere in history.
        answered_ids = history
                       .select { |m| m.role == "tool" && m.tool_call_id }
                       .map(&:tool_call_id)
                       .to_set

        repaired = []
        history.each do |msg|
          if msg.role == "tool" && msg.tool_call_id
            # Drop a result whose triggering assistant call is gone.
            next unless declared_ids.include?(msg.tool_call_id)

            repaired << msg
          elsif sanitizer.assistant_tool_call?(msg)
            ids = sanitizer.tool_call_ids(msg)
            if ids.any? { |id| answered_ids.include?(id) }
              # At least one result present → keep the call intact. Partial
              # answers stay as-is (pruning would re-orphan the kept result).
              repaired << msg
            else
              # No results at all → strip tool_calls so we don't emit a toolUse
              # with no following toolResult. Keep the surrounding prose if any.
              stripped = strip_tool_calls(msg)
              repaired << stripped if stripped
            end
          else
            repaired << msg
          end
        end

        repaired
      end

      # Returns a copy of an assistant message with tool_calls removed, or nil
      # when the message would be empty afterwards (nothing left to send).
      def strip_tool_calls(msg)
        return nil if msg.content.nil? || msg.content.to_s.strip.empty?

        metadata = msg.metadata.is_a?(Hash) ? msg.metadata.dup : {}
        metadata.delete(:tool_calls)
        metadata.delete("tool_calls")

        Session::Message.new(
          id: msg.id,
          session_id: msg.session_id,
          role: msg.role,
          content: msg.content,
          tool_name: msg.tool_name,
          tool_call_id: msg.tool_call_id,
          token_count: msg.token_count,
          metadata: metadata,
          created_at: msg.created_at
        )
      end

      # Assembles the system prompt as a stack of labelled blocks, split into a
      # STABLE PREFIX and a VOLATILE TAIL for prompt caching (#311):
      #   PREFIX (cached): 1. Identity 2. Product preamble 3. Environment
      #                    4. User profile 5. Skills index 6. Project context
      #   TAIL (uncached): 7. Relevant memories 8. Session summary
      # Each block is independent: if a section is empty/disabled it just
      # drops out without leaving a stray header.
      # The system message content. When prompt caching is enabled (the
      # default) this is a RubyLLM::Content::Raw array of text blocks — the
      # STABLE PREFIX block carries an Anthropic cache_control breakpoint (#311),
      # the VOLATILE TAIL block (when present) does not — so the cached prefix
      # bytes stay identical across turns. When caching is disabled it is the
      # plain joined String (prefix + tail), byte-identical to the pre-#311
      # single-string output, so non-anthropic providers and the existing
      # String-shaped contract are unaffected.
      def system_content
        prefix = stable_prefix
        tail   = volatile_tail

        unless prompt_cache_enabled?
          return tail.empty? ? prefix : "#{prefix}\n\n#{tail}"
        end

        blocks = [{ type: "text", text: prefix, cache_control: { type: "ephemeral" } }]
        # The tail rides in its OWN, UNCACHED block AFTER the breakpoint. Without
        # a tail the system block is just the one cached prefix block.
        blocks << { type: "text", text: tail } unless tail.empty?
        ::RubyLLM::Content::Raw.new(blocks)
      end

      # Back-compat shim: the full system prompt as a single String (prefix +
      # tail), the pre-#311 shape. Retained for any caller/spec that wants the
      # rendered text regardless of the cache wire-shape.
      def build_system_prompt
        prefix = stable_prefix
        tail   = volatile_tail
        tail.empty? ? prefix : "#{prefix}\n\n#{tail}"
      end

      # The STABLE region of the system prompt — the bytes BEFORE the cache
      # breakpoint. Every section here is session-stable: the identity/product
      # text is fixed, the [Environment] block is process-cached, and the memory
      # snapshot ([User Profile]) is FROZEN per session (see @snapshots). So
      # these bytes are byte-identical on turn 2..N of a session — exactly what
      # the prompt-cache prefix requires. Freshly-retrieved [Relevant Memories]
      # and the post-compaction [Session Summary] are deliberately NOT here —
      # they go in the volatile tail.
      def stable_prefix
        # Memory snapshot is frozen for the lifetime of the session — see
        # the class-level @snapshots cache for why. The first assembly in
        # a session captures @memory_context; later assemblies reuse it
        # even if Memory::Store has been mutated in the meantime.
        snapshot = self.class.snapshot_for(@session[:id]) { @memory_context }

        parts = []
        parts << agent_identity
        product = product_preamble
        parts << "[Product]\n#{product}" if product
        env = environment_block
        parts << env if env

        if snapshot[:user_profile] && !snapshot[:user_profile].empty?
          parts << "[User Profile]\n#{snapshot[:user_profile]}"
        end

        skills_index = skills_index_block
        parts << skills_index if skills_index

        # The user-PINNED active skill (the `/skills <name>` picker): force-load
        # its full SKILL.md into the prompt EACH turn so the model actually uses
        # it, not just shows a chip. Sits after the skills index so the pinned
        # skill is the most concrete, last-read instruction in the skills region.
        active_skill = active_skill_block
        parts << active_skill if active_skill

        project_ctx = load_project_context
        parts << "[Project Context]\n#{project_ctx}" if project_ctx

        parts.join("\n\n")
      end

      # The VOLATILE region — the bytes AFTER the cache breakpoint. These can
      # change turn-to-turn within a session, so caching them would invalidate
      # the prefix on every change (#311):
      #   - [Relevant Memories]: a relevance-aware backend re-ranks recall per
      #     turn against the new user message, so the set is not session-stable.
      #     (The default backend returns a stable set; either way it is safe
      #     here — correctness is unchanged, only cacheability differs.)
      #   - [Session Summary]: written by compaction MID-session, so it appears
      #     (and grows) part-way through; keeping it out of the prefix means a
      #     compaction does not bust the cached prefix.
      def volatile_tail
        snapshot = self.class.snapshot_for(@session[:id]) { @memory_context }

        parts = []

        if snapshot[:relevant_memories]&.any?
          memories_text = snapshot[:relevant_memories].map { |m| "- #{m[:content]}" }.join("\n")
          parts << "[Relevant Memories]\n#{memories_text}"
        end

        summary = load_summary
        parts << "[Session Summary]\n#{summary}" if summary

        parts.join("\n\n")
      end

      # Prompt-cache breakpoints are emitted only when (a) caching is enabled in
      # config (default on) AND (b) the resolved provider is anthropic-family —
      # cache_control is an Anthropic concept and openai-style endpoints reject
      # the extra wire keys. The adapter applies the SAME gate to the tool
      # breakpoint (#tool_cache_breakpoint?), so the two breakpoints stay paired.
      def prompt_cache_enabled?
        config_value = @config.dig("prompts", "prompt_cache")
        return false unless config_value.nil? || config_value == true

        anthropic_family_provider?
      rescue StandardError
        false
      end

      # Mirrors RubyLLMAdapter#anthropic_generation_path? from config: an
      # explicit anthropic/bedrock provider, the Bedrock-bearer override, or a
      # provider declaring anthropic_compatible: true (e.g. MiniMax /anthropic).
      def anthropic_family_provider?
        provider = LLM::ProviderResolver.resolve(
          @session[:model], explicit_provider: @config.model_provider
        )
        return true if %w[anthropic bedrock].include?(provider.to_s)

        @config.provider_config(provider)["anthropic_compatible"] == true
      rescue StandardError
        false
      end

      # The "## Skills (mandatory)" catalogue. This is the load-bearing trigger
      # for skill auto-activation — surfacing skills in the system prompt (not
      # just the `skill` tool description) is what makes the model proactively
      # scan and load a relevant skill before replying.
      #
      # Gated, mirroring the reference (which gates on the skills
      # toolset being present), on both holding:
      #   - the skills feature is enabled (config skills.enabled), and
      #   - the `skill` tool is actually available this turn.
      # When either fails we inject nothing. When both hold we always inject the
      # block, even with zero skills discovered: the catalogue half drops out but
      # the proactive-creation nudge remains, so a fresh install still gets told
      # to distill repeatable work into a skill (PromptIndex#render handles the
      # empty-catalogue case and never returns nil).
      def skills_index_block
        return nil unless skills_feature_enabled?
        return nil unless skill_tool_available?

        Skills::PromptIndex.new(
          registry: Skills::Registry.new(
            config: @config,
            include_project_local: project_local_trusted?
          )
        ).render
      rescue StandardError
        nil
      end

      # The user-PINNED active skill block. When the user has activated a skill
      # via the `/skills <name>` picker (Rubino::ActiveSkill), we force-load its
      # FULL SKILL.md content into the system prompt every turn and prepend a
      # strong directive naming it — so the model treats it as active and follows
      # it without having to discover/load it via the `skill` tool. This is the
      # load-bearing half of the picker: the chip is cosmetic, THIS is what makes
      # the skill actually take effect.
      #
      # Gated on the skills feature being enabled (same gate as the index). A
      # pinned-but-now-missing/disabled skill (deleted on disk, or toggled off)
      # silently drops out rather than injecting an empty block. Never raises —
      # a load failure must not take down prompt assembly — but it LOGS, so a
      # logic error here (e.g. a signature drift) is visible instead of the
      # pinned skill silently vanishing from the prompt (#62).
      def active_skill_block
        return nil unless skills_feature_enabled?

        name = Rubino::ActiveSkill.current
        return nil unless name

        registry = Skills::Registry.new(
          config: @config,
          include_project_local: project_local_trusted?
        )
        return nil unless registry.enabled?(name)

        content = registry.load_skill(name)
        return nil if content.nil? || content.to_s.strip.empty?

        <<~PROMPT.strip
          ## Active skill (pinned): #{name}
          The user has PINNED the "#{name}" skill active for this session. You MUST follow its instructions for this and every subsequent turn until it is changed. Its full content is loaded below — treat it as authoritative; you do not need to load it again with the `skill` tool.

          <active_skill name="#{name}">
          #{content.to_s.strip}
          </active_skill>
        PROMPT
      rescue StandardError => e
        Rubino.logger.debug(event: "prompt.active_skill_block_failed",
                            error: "#{e.class}: #{e.message}")
        nil
      end

      def skills_feature_enabled?
        value = @config.dig("skills", "enabled")
        value.nil? || value == true
      end

      # True when the `skill` tool is exposed to the model this turn. Honors the
      # agent definition's tool restrictions when present, else falls back to the
      # globally enabled tools — the same source the loop uses to pick tools.
      def skill_tool_available?
        tools =
          if @agent_definition
            @agent_definition.resolved_tools
          else
            Tools::Registry.instance.enabled_tools
          end
        tools.any? { |t| t.respond_to?(:name) && t.name == "skill" }
      rescue StandardError
        false
      end

      def agent_identity
        return @agent_definition.system_prompt if @agent_definition&.system_prompt

        load_builtin_prompt("build") || <<~FALLBACK.strip
          You are a helpful AI assistant powered by rubino.
          You can use tools to help accomplish tasks.
          Be concise and accurate in your responses.
        FALLBACK
      end

      def product_preamble
        return nil unless @config.respond_to?(:prompts_preamble)

        @config.prompts_preamble
      end

      def environment_block
        return nil unless environment_enabled?

        EnvironmentInspector.new(
          extra_utilities: environment_extra_utilities
        ).render
      rescue StandardError
        # The env block is a convenience; never let a probe failure
        # (read-only filesystem, missing `git`, weird PATH) take down the
        # whole interaction.
        nil
      end

      def environment_enabled?
        return true unless @config.respond_to?(:prompts_environment_enabled?)

        @config.prompts_environment_enabled?
      end

      def environment_extra_utilities
        return [] unless @config.respond_to?(:prompts_environment_extra_utilities)

        @config.prompts_environment_extra_utilities
      end

      def load_builtin_prompt(name)
        path = File.expand_path("../agent/prompts/#{name}.txt", __dir__)
        File.exist?(path) ? File.read(path, encoding: "UTF-8").strip : nil
      rescue StandardError
        nil
      end

      def load_summary
        Session::SummaryStore.new.latest_content(@session[:id])
      rescue StandardError
        nil
      end

      def load_project_context
        return nil if @ignore_rules
        return nil unless @config.dig("memory", "project_context_enabled")
        return nil unless project_local_trusted?

        # Discover from the PRIMARY workspace root (not just Dir.pwd) so project
        # context tracks terminal.cwd and the dir the trust gate vouched for.
        discovery = Context::FileDiscovery.new(base_path: Rubino::Workspace.primary_root)
        discovery.load_project_context
      rescue StandardError
        nil
      end

      # Folder-trust gate (proportionate; see Rubino::Trust). The cwd's
      # AGENTS.md/etc. and its .rubino/skills are auto-injected into the system
      # prompt, so a hostile repo could STEER the agent the moment you start
      # there. We withhold that project-local context until the primary root is
      # trusted — the CLI prompts once at boot / on /add-dir and remembers the
      # answer. An already-trusted dir (or one the user never gated, e.g. a bare
      # scratch dir with no context files) loads normally.
      def project_local_trusted?
        Rubino::Trust.trusted?(Rubino::Workspace.primary_root)
      rescue StandardError
        # Never let the trust check itself drop context on a real error; the
        # boot-time prompt is the authoritative gate, this is defence-in-depth.
        true
      end
    end
  end
end
