# frozen_string_literal: true

require "fileutils"

module Rubino
  module UI
    # The per-session PASTE store behind the composer's file-backed paste
    # pipeline (Hermes-style, two tiers).
    #
    # A large bracketed paste does not flood the composer: the body is
    # registered here and a single compact PLACEHOLDER token —
    # "[Pasted text #1 +123 lines]" — is inserted into the editable buffer
    # instead. The token rides the draft like normal text (editable around,
    # history-recalled, queueable) and is EXPANDED to the full body only at
    # the message-build seam, where the line leaves the composer for the
    # agent loop (ChatCommand#run_turn): the model sees everything, while the
    # transcript echo keeps the placeholder so scrollback stays clean.
    #
    # Two tiers, both behind one placeholder shape:
    #
    #   * Tier 1 — PLACEHOLDER COLLAPSE: a paste longer than
    #     `paste.collapse_lines` lines (default 5) is held in memory and the
    #     token expands to the verbatim body at submit.
    #   * Tier 2 — FILE OVERFLOW: a paste bigger than
    #     `paste.file_threshold_tokens` (default 8000, estimated at the same
    #     chars/4 rule Context::TokenBudget uses) is written to a session-
    #     scoped file — <RUBINO_HOME>/sessions/<id>/paste_N.txt — and the
    #     token expands to a one-line pointer telling the model to read the
    #     file with the read tool. The home sessions dir is where session
    #     artifacts already live, it never pollutes the workspace tree, and
    #     the read tool is deliberately un-sandboxed (only WRITES are gated
    #     by Workspace roots), so the model can read it from any cwd.
    #
    # Lifecycle: a tier-1 body is consumed when its token is expanded into an
    # outgoing message (re-submitting the line from history later leaves the
    # literal placeholder, matching Hermes); tier-2 files persist for the
    # session so the model can re-read them in later turns. Pastes at or
    # under the collapse threshold never reach the store — they inline into
    # the buffer exactly as before.
    class PasteStore
      # The placeholder shape, shared with the CompletionSource highlight and
      # the composer's whole-token backspace.
      TOKEN_RE = /\[Pasted text #\d+ \+\d+ lines\]/

      # Built-in fallbacks when config is missing/garbage.
      DEFAULT_COLLAPSE_LINES   = 5
      DEFAULT_THRESHOLD_TOKENS = 8000

      # @param config [Config::Configuration, nil] resolved lazily from
      #   Rubino.configuration when nil, so a long-lived store follows config
      #   reloads.
      # @param session_source [#call, String, nil] the session id the tier-2
      #   files are scoped under. A callable is resolved at WRITE time, so the
      #   chat loop can hand a closure over its (re-assignable) runner and
      #   /new //sessions //branch swaps are honored without re-wiring.
      def initialize(config: nil, session_source: nil)
        @config         = config
        @session_source = session_source
        @entries        = {} # placeholder token => expansion text
        @counter        = 0
      end

      # Late wiring for the session scope (see #initialize) — the chat command
      # builds the store before the runner exists.
      attr_writer :session_source

      # True when +body+ should collapse to a placeholder instead of inlining:
      # strictly more lines than paste.collapse_lines.
      def collapse?(body)
        body.to_s.lines.length > collapse_lines
      end

      # Registers a pasted +body+ and returns the placeholder token to insert
      # into the buffer. Oversized bodies (tier 2) are written to the session
      # paste file here, at paste time; their token expands to the file
      # pointer instead of the content.
      def register(body)
        body  = body.to_s
        n     = (@counter += 1)
        token = "[Pasted text ##{n} +#{body.lines.length} lines]"
        @entries[token] = oversize?(body) ? overflow_to_file(n, body) : body
        token
      end

      # Expands every registered placeholder in +text+ to its stored body
      # (tier 1) or file pointer (tier 2) — the message-build seam. Consumed
      # entries are dropped ("cleared on submit"); unknown placeholder-shaped
      # text is left verbatim, so user-typed literals are never rewritten.
      def expand(text)
        return text unless text.is_a?(String) && @entries.keys.any? { |t| text.include?(t) }

        text.gsub(TOKEN_RE) { |token| @entries.delete(token) || token }
      end

      # The [start, length] (codepoint) span of the registered placeholder
      # covering the char just BEFORE +cursor+ in +buffer+, or nil. The
      # composer's backspace uses it to delete a placeholder WHOLE — a
      # half-eaten token would neither read nor expand. Only spans the store
      # actually registered qualify; lookalike text the user typed is edited
      # char-by-char as usual.
      def placeholder_span(buffer, cursor)
        return nil if @entries.empty? || buffer.nil?

        pos = 0
        while (m = TOKEN_RE.match(buffer, pos))
          start  = m.begin(0)
          length = m[0].length
          return [start, length] if @entries.key?(m[0]) && cursor > start && cursor <= start + length

          pos = start + length
        end
        nil
      end

      private

      def collapse_lines
        positive(config&.paste_collapse_lines) || DEFAULT_COLLAPSE_LINES
      end

      def threshold_tokens
        positive(config&.paste_file_threshold_tokens) || DEFAULT_THRESHOLD_TOKENS
      end

      # Tier-2 gate: the same chars/4 estimate compaction runs on
      # (Context::TokenBudget::CHARS_PER_TOKEN), so "a context share" here and
      # the status bar / compactor agree on what a token is.
      def oversize?(body)
        (body.length / Context::TokenBudget::CHARS_PER_TOKEN) > threshold_tokens
      end

      # Write the oversized body to <home>/sessions/<id>/paste_N.txt and
      # return the pointer line its token expands to. Best-effort: if the
      # write fails for any reason the body is kept in memory (tier-1
      # behavior) — a paste must never be lost to a disk hiccup.
      def overflow_to_file(num, body)
        dir = session_dir
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "paste_#{num}.txt")
        File.write(path, body)
        "[Pasted text ##{num} saved to #{path} — too large to inline; read it with the read tool]"
      rescue StandardError
        body
      end

      def session_dir
        id = @session_source.respond_to?(:call) ? @session_source.call : @session_source
        id = "pastes-#{Process.pid}" if id.nil? || id.to_s.empty?
        File.join(Rubino.home_path, "sessions", id.to_s)
      end

      def config
        @config || Rubino.configuration
      end

      def positive(value)
        v = value.to_i
        v.positive? ? v : nil
      end
    end
  end
end
