# frozen_string_literal: true

require "timeout"

module Rubino
  module Tools
    # Tool that asks the user interactive questions with predefined options.
    # Allows the agent to gather clarification or preferences from the user.
    class QuestionTool < Base
      def name
        "question"
      end

      def description
        "Ask the user a question with optional predefined choices. " \
          "Use this when you need clarification, user preferences, or a decision. " \
          "The user can select from options or type a custom answer."
      end

      def input_schema
        {
          type: "object",
          properties: {
            question: {
              type: "string",
              description: "The question to ask the user"
            },
            options: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  label: { type: "string", description: "Short display text for the option" },
                  description: { type: "string", description: "Explanation of this choice" }
                },
                required: %w[label]
              },
              description: "Available choices (optional). A 'Type your own' option is added automatically."
            },
            multiple: {
              type: "boolean",
              description: "Allow selecting multiple choices (default: false)"
            }
          },
          required: %w[question]
        }
      end

      def risk_level
        :low
      end

      # Deterministic result when no user answer is available — the UI's #ask
      # returned nil (non-interactive / piped session, or the user gave no
      # response). Fail closed instead of reading ambient stdin or silently
      # picking an option (#107): never assume a choice on the user's behalf.
      NO_ANSWER = "No answer: no interactive user input available " \
                  "(non-interactive session, or the user gave no response). " \
                  "Do not assume a choice on the user's behalf; proceed with the " \
                  "safest option and state the assumption, or finish and report " \
                  "the open question."

      # #552: clean, NON-ERROR outcome when the human did not answer within the
      # generous clarify timeout. Mirrors ask_parent's "proceed with your best
      # judgement" expiry and Hermes' falsy clarify response — the run continues,
      # nothing is raised, no choice is assumed on the user's behalf.
      TIMED_OUT = "No answer: the question timed out waiting for a reply. " \
                  "Do not assume a choice on the user's behalf; proceed with the " \
                  "safest option and state the assumption, or finish and report " \
                  "the open question."

      # Fallback bound (seconds) when no configuration is reachable (a bare tool
      # in a unit test). The live value comes from clarify.timeout.
      DEFAULT_CLARIFY_TIMEOUT = 600

      # Distinct from a plain nil (non-interactive session): EXPIRED means the
      # human was asked but did not answer within clarify.timeout, so the caller
      # surfaces TIMED_OUT (still a clean, non-error outcome) rather than the
      # NO_ANSWER "no interactive input available" message.
      EXPIRED = Object.new.freeze

      def call(arguments)
        question = arguments["question"] || arguments[:question]
        options = arguments["options"] || arguments[:options]
        multiple = arguments["multiple"] || arguments[:multiple] || false

        ui = Rubino.ui

        if options && !options.empty?
          ask_with_options(ui, question, options, multiple)
        else
          ask_freeform(ui, question)
        end
      end

      private

      # Blocks on the human's answer, BOUNDED by clarify.timeout (default 600s,
      # #552). The stale-chunk watchdog is independently suspended for the tool's
      # whole runtime (RubyLLMAdapter#stream_once keys it off before_tool_call),
      # so this is the ONLY bound on the wait — and it expires CLEANLY: on
      # timeout it returns nil so the caller emits the TIMED_OUT outcome instead
      # of raising. A generous bound (well above human reading time) means a
      # deliberating user is never cut off, while an abandoned prompt still
      # self-heals rather than parking the run forever. The CLI's #ask runs
      # inside BottomComposer.run_in_terminal, whose ensure restores the terminal
      # even when Timeout fires mid-prompt, so a timed-out clarify leaves the TUI
      # in a clean state.
      def prompt_with_timeout(ui, prompt)
        Timeout.timeout(clarify_timeout) { ui.ask(prompt) }
      rescue Timeout::Error
        EXPIRED
      end

      # The configured clarify wait (clarify.timeout) when wired, else the
      # built-in default. nil/<=0 disables the bound (wait as long as the UI
      # blocks) — matching ask_parent's "never forever, but configurable" stance.
      def clarify_timeout
        cfg = Rubino.configuration if defined?(Rubino) && Rubino.respond_to?(:configuration)
        val = cfg.respond_to?(:clarify_timeout) ? cfg.clarify_timeout : nil
        seconds = Float(val)
        seconds.positive? ? seconds : nil
      rescue StandardError
        DEFAULT_CLARIFY_TIMEOUT
      end

      def ask_with_options(ui, question, options, multiple)
        # Format options for display
        formatted = options.map do |opt|
          label = opt["label"] || opt[:label]
          desc  = opt["description"] || opt[:description]
          desc ? "#{label} - #{desc}" : label
        end

        # Build a SINGLE prompt carrying the question, the numbered options, the
        # multiple-select hint, and the trailing instruction. On the API path the
        # whole prompt becomes the clarify.required event's `question` payload, so
        # the web clarify box renders the question next to the input (instead of
        # only the generic "Your choice…" line, with the question lost up top).
        lines = [question]
        formatted.each_with_index do |opt, i|
          lines << "  #{i + 1}. #{opt}"
        end
        lines << "  (Select multiple numbers separated by commas, or type a custom answer)" if multiple
        lines << "Your choice#{"(s)" if multiple} (number or custom answer):"

        answer = prompt_with_timeout(ui, lines.join("\n"))
        return TIMED_OUT if answer.equal?(EXPIRED)
        return NO_ANSWER if answer.nil?

        # Parse single or multiple numeric selections
        if multiple && answer&.match?(/\A[\d,\s]+\z/)
          indices = answer.scan(/\d+/).map { |n| n.to_i - 1 }
          selected = indices.filter_map do |idx|
            options[idx]["label"] || options[idx][:label] if idx >= 0 && idx < options.size
          end
          selected.empty? ? "User answered: #{answer}" : "User selected: #{selected.join(", ")}"
        elsif answer&.match?(/\A\d+\z/)
          idx = answer.to_i - 1
          if idx >= 0 && idx < options.size
            selected = options[idx]
            "User selected: #{selected["label"] || selected[:label]}"
          else
            "User answered: #{answer}"
          end
        else
          "User answered: #{answer}"
        end
      end

      def ask_freeform(ui, question)
        answer = prompt_with_timeout(ui, question)
        return TIMED_OUT if answer.equal?(EXPIRED)
        return NO_ANSWER if answer.nil?

        "User answered: #{answer}"
      end
    end
  end
end
