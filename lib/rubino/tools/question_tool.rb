# frozen_string_literal: true

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

        answer = ui.ask(lines.join("\n"))
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
        answer = ui.ask(question)
        return NO_ANSWER if answer.nil?

        "User answered: #{answer}"
      end
    end
  end
end
