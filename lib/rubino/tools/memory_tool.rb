# frozen_string_literal: true

module Rubino
  module Tools
    # Agent-callable interface to the memory store.
    #
    # The agent uses this to record durable facts about the user or
    # project across sessions. The schema is deliberately tiny — three
    # actions, two targets — because every additional knob is another
    # surface a prompt-injection attempt can probe. Threat scanning and
    # the char-budget run inside Memory::Store; this tool only handles
    # the action/target mapping and translates Store exceptions into
    # tool-protocol error strings.
    class MemoryTool < Base
      VALID_ACTIONS = %w[add replace remove].freeze
      VALID_TARGETS = %w[memory user].freeze

      # target → memory kind. "user" is the user_profile slot; "memory"
      # is the catch-all "fact" kind. Other kinds (preference,
      # technical_decision, …) are reserved for the auto-extractor — the
      # agent does not get to write to them directly through this tool.
      TARGET_TO_KIND = { "memory" => "fact", "user" => "user_profile" }.freeze

      def initialize(backend: nil)
        @backend = backend
      end

      def name
        "memory"
      end

      def description
        "Persist facts across sessions. Use action=add to record a new fact, " \
          "replace to update an existing fact (substring match on old_text), " \
          "or remove to delete one. target=user writes to the user profile; " \
          "target=memory writes to general memory. " \
          "Store ONE atomic fact per call — make separate calls for separate " \
          "facts so each can be superseded or forgotten independently. " \
          "Content is scanned for prompt-injection / exfiltration patterns and " \
          "subject to a character budget — refusals are reported in the output."
      end

      def input_schema
        {
          type: "object",
          properties: {
            action: {
              type: "string",
              enum: VALID_ACTIONS,
              description: "add, replace, or remove"
            },
            target: {
              type: "string",
              enum: VALID_TARGETS,
              description: "memory (general) or user (user profile)"
            },
            content: {
              type: "string",
              description: "New content (required for add and replace)"
            },
            old_text: {
              type: "string",
              description: "Substring of existing memory to match " \
                           "(required for replace and remove)"
            }
          },
          required: %w[action target]
        }
      end

      def risk_level
        # Memory store/retrieve/update is an internal, low-risk operation:
        # an autonomous "scratchpad" the agent maintains, not an external
        # side-effect like editing the user's files or running a shell
        # command. It must not trip the approval gate. Every write is
        # already threat-scanned and char-budgeted inside Memory::Store,
        # and the only destructive action (remove) deletes a SINGLE entry
        # by substring match — there is no full-wipe op exposed here — so
        # there is nothing left for an approval prompt to guard.
        # :low keeps it autonomous even under approvals.mode: manual
        # (Base#risky? only flags :medium/:high), matching how todo_tool
        # and other internal state-mutating tools stay unprompted.
        :low
      end

      def call(arguments)
        args = symbolize(arguments)
        action = args[:action].to_s
        target = args[:target].to_s

        return error("invalid action '#{action}'; expected one of #{VALID_ACTIONS.join(", ")}") \
          unless VALID_ACTIONS.include?(action)
        return error("invalid target '#{target}'; expected one of #{VALID_TARGETS.join(", ")}") \
          unless VALID_TARGETS.include?(target)

        kind = TARGET_TO_KIND.fetch(target)

        case action
        when "add"     then do_add(kind, args[:content])
        when "replace" then do_replace(kind, args[:old_text], args[:content])
        when "remove"  then do_remove(kind, args[:old_text])
        end
      end

      private

      def backend
        @backend ||= Memory::Backends.build
      end

      def do_add(kind, content)
        return error("content is required for add") if blank?(content)

        memory = backend.store(kind: kind, content: content)
        "Memory added (id=#{memory[:id][0, 8]}, kind=#{kind})."
      rescue Memory::Store::ThreatDetectedError => e
        threat_error(e)
      rescue Memory::Store::BudgetExceededError => e
        budget_error(e)
      end

      def do_replace(kind, old_text, content)
        return error("old_text is required for replace") if blank?(old_text)
        return error("content is required for replace") if blank?(content)

        target = backend.replace(kind: kind, old_text: old_text, content: content)
        return error("no #{kind} memory matched substring '#{truncate(old_text)}'") unless target

        "Memory replaced (id=#{target[:id][0, 8]}, kind=#{kind})."
      rescue Memory::Store::ThreatDetectedError => e
        threat_error(e)
      rescue Memory::Store::BudgetExceededError => e
        budget_error(e)
      end

      def do_remove(kind, old_text)
        return error("old_text is required for remove") if blank?(old_text)

        target = backend.forget(kind: kind, old_text: old_text)
        return error("no #{kind} memory matched substring '#{truncate(old_text)}'") unless target

        "Memory removed (id=#{target[:id][0, 8]}, kind=#{kind})."
      end

      def threat_error(err)
        {
          output: "Error: refused to write memory (#{err.threat}). " \
                  "Memory content was rejected by the threat scanner.",
          error_code: :memory_threat_detected
        }
      end

      def budget_error(err)
        {
          output: "Error: memory budget exceeded; delete or replace older entries first " \
                  "(group=#{err.group}, used=#{err.current}, requested=#{err.requested}, " \
                  "limit=#{err.limit}).",
          error_code: :memory_budget_exceeded
        }
      end

      def error(msg)
        "Error: #{msg}"
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def truncate(text, max: 40)
        s = text.to_s
        s.length > max ? "#{s[0, max]}..." : s
      end

      def symbolize(arguments)
        return {} unless arguments.is_a?(Hash)

        arguments.each_with_object({}) do |(k, v), acc|
          acc[k.to_sym] = v
        end
      end
    end
  end
end
