# frozen_string_literal: true

require "faraday"
require "json"

module Rubino
  module LLM
    # Faraday request middleware that stamps an Anthropic prompt-cache breakpoint
    # on the GROWING conversation tail of EVERY outgoing /messages request — the
    # last content block of the last message, advancing one block each turn.
    #
    # Why a Faraday middleware (and not the adapter's turn-boundary code):
    # ruby_llm 1.16 runs the WHOLE model<->tool loop inside a single ask(), so
    # the intermediate tool round-trips never re-enter rubino's per-turn code.
    # The ONLY seam that sees every actual outgoing request — including those
    # intermediate tool round-trips — is a Faraday request middleware on the
    # Anthropic connection (it runs after ruby_llm has serialized the body). This
    # is exactly the round-trip #532's load_history tail-stamping missed: that
    # ran once per ask(), never on the tool turns inside it.
    #
    # Wire shape (Anthropic "growing conversation" / longest-cached-prefix):
    # cache_control: {type: ephemeral} is a wire-valid SIBLING key on a content
    # block. We add it to the LAST block of the LAST message UNCONDITIONALLY —
    # whether that block is text, tool_use (assistant tail) or tool_result (user
    # tail). We never restructure the block; a bare-string message content is
    # skipped (no block to stamp).
    #
    # Breakpoint budget: Anthropic allows at most 4 cache_control breakpoints per
    # request (across tools + system + messages). rubino already places 2 static
    # ones (last tool schema, system prefix). This middleware adds 1 (the moving
    # tail) and, on a very long turn, an optional 2nd "leapfrog" breakpoint ~15
    # blocks behind the tail so a long burst of tool round-trips still gets a
    # cache READ of the earlier blocks. If stamping would exceed 4, we evict the
    # OLDEST message-level breakpoint first — never a system or tools breakpoint.
    #
    # The middleware is installed by RubyLLMAdapter ONLY on the anthropic-family
    # path and only when prompts.prompt_cache is on; openai/ollama connections
    # never carry it. It is fully defensive: any parse/shape surprise leaves the
    # body byte-identical.
    class CacheBreakpointMiddleware < Faraday::Middleware
      EPHEMERAL = { "type" => "ephemeral" }.freeze

      # Anthropic hard cap on cache_control breakpoints per request.
      MAX_BREAKPOINTS = 4

      # A turn longer than this (content blocks in the messages array) earns the
      # optional second "leapfrog" breakpoint, placed LOOKBACK blocks behind the
      # tail so a long run of tool round-trips still reads the earlier prefix.
      LEAPFROG_THRESHOLD = 20
      LEAPFROG_LOOKBACK  = 15

      def call(env)
        stamp!(env)
        @app.call(env)
      rescue StandardError
        # Never let cache bookkeeping break a real request — forward untouched.
        @app.call(env)
      end

      private

      # Mutate env.request_body in place when it is the Hash ruby_llm built (we
      # install BEFORE Faraday::Request::Json, so the body is still a Hash). A
      # String body (middleware ordered after Json, or a pre-serialized payload)
      # is parsed, restamped and reserialized as a defensive fallback.
      def stamp!(env)
        body = env.request_body
        case body
        when Hash
          apply(body)
        when String
          parsed = JSON.parse(body)
          return unless parsed.is_a?(Hash)

          apply(parsed)
          env.request_body = JSON.generate(parsed)
        end
      end

      # Stamp the moving tail (and optional leapfrog) on an Anthropic messages
      # payload, honoring the 4-breakpoint cap. +body+ is mutated in place.
      def apply(body)
        messages = body["messages"] || body[:messages]
        return unless messages.is_a?(Array) && !messages.empty?

        tail_blocks = block_array(messages.last)
        return if tail_blocks.nil? || tail_blocks.empty? # bare-string content: nothing to stamp

        targets = breakpoint_targets(messages, tail_blocks)
        return if targets.empty?

        # Budget: count the breakpoints already on tools + system (static, never
        # evicted) plus any already on message blocks, then add ours. If we would
        # exceed the cap, evict the OLDEST message-level breakpoint(s) first.
        enforce_cap(body, messages, targets)

        targets.each { |block| stamp_block(block) }
      end

      # The block(s) we want to stamp this request: always the tail block; plus a
      # leapfrog block ~LOOKBACK behind it when the whole turn is long. Both are
      # taken from a flat, ordered view of every message content block so the
      # leapfrog can sit in an EARLIER message than the tail.
      def breakpoint_targets(messages, tail_blocks)
        tail = tail_blocks.last
        return [] unless stampable?(tail)

        targets = [tail]

        flat = flat_blocks(messages)
        if flat.size > LEAPFROG_THRESHOLD
          leap = flat[flat.size - 1 - LEAPFROG_LOOKBACK]
          targets.unshift(leap) if leap && stampable?(leap) && !leap.equal?(tail)
        end
        targets
      end

      # Keep the request within MAX_BREAKPOINTS. Static breakpoints (tools +
      # system) are sacred; message-level breakpoints are the only ones we evict,
      # oldest first, to make room for the +targets+ we are about to add.
      def enforce_cap(body, messages, targets)
        static = static_breakpoint_count(body)
        existing = message_breakpoint_blocks(messages)

        # Blocks we are about to (re)stamp don't count as new if they already
        # carry a breakpoint — restamping is idempotent.
        adding = targets.count { |b| !breakpoint?(b) }

        budget = MAX_BREAKPOINTS - static
        # Evict oldest message-level breakpoints until existing + adding fits.
        while existing.size + adding > budget && !existing.empty?
          oldest = existing.shift
          oldest.delete("cache_control")
          oldest.delete(:cache_control)
        end
      end

      def static_breakpoint_count(body)
        count = 0
        tools = body["tools"] || body[:tools]
        count += Array(tools).count { |t| t.is_a?(Hash) && breakpoint?(t) }
        count += system_breakpoint_count(body["system"] || body[:system])
        count
      end

      def system_breakpoint_count(system)
        case system
        when Array then system.count { |b| b.is_a?(Hash) && breakpoint?(b) }
        else 0
        end
      end

      # Every message content block, in wire order, that could carry a breakpoint
      # and currently does — oldest first (eviction order).
      def message_breakpoint_blocks(messages)
        flat_blocks(messages).select { |b| breakpoint?(b) }
      end

      # A flat, ordered list of every Hash content block across all messages.
      def flat_blocks(messages)
        messages.flat_map { |m| block_array(m) || [] }
      end

      # The content blocks of a single message, or nil when content is a bare
      # string (or otherwise has no stampable block array).
      def block_array(message)
        return nil unless message.is_a?(Hash)

        content = message["content"]
        content = message[:content] if content.nil?
        case content
        when Array then content.grep(Hash)
        end
      end

      # Only stamp a block that already looks like a structured content block
      # (has a "type"); never a stray hash.
      def stampable?(block)
        block.is_a?(Hash) && (block.key?("type") || block.key?(:type))
      end

      def breakpoint?(hash)
        hash.is_a?(Hash) && (hash.key?("cache_control") || hash.key?(:cache_control))
      end

      def stamp_block(block)
        return unless block.is_a?(Hash)
        return if breakpoint?(block)

        block["cache_control"] = EPHEMERAL.dup
      end
    end
  end
end
