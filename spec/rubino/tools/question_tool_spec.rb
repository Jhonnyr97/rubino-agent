# frozen_string_literal: true

# The `question` tool asks the user a multi-choice or freeform question. The
# important contract (regression-tested here) is that ask_with_options passes a
# SINGLE combined prompt to ui.ask — question + numbered options + trailing
# instruction — because on the API path that prompt becomes the
# clarify.required event's `question`, which the web clarify box renders next to
# the input. Emitting the question/options as separate ui.info lines made them
# render disconnected from the answer box ("the question gets lost up top").
RSpec.describe Rubino::Tools::QuestionTool do
  subject(:tool) { described_class.new }

  let(:ui) { instance_double(Rubino::UI::Base) }

  before do
    allow(Rubino).to receive(:ui).and_return(ui)
    # Default: ui.info is a no-op; individual examples assert if needed.
    allow(ui).to receive(:info)
  end

  describe "#call with options (ask_with_options)" do
    let(:options) do
      [
        { "label" => "Postgres", "description" => "relational, ACID" },
        { "label" => "Redis", "description" => "in-memory KV" }
      ]
    end

    it "passes a single combined prompt to ui.ask containing the question and option labels" do
      captured = nil
      allow(ui).to receive(:ask) { |prompt|
        captured = prompt
        "1"
      }

      tool.call("question" => "Which datastore?", "options" => options)

      expect(ui).to have_received(:ask).once
      expect(captured).to include("Which datastore?")
      expect(captured).to include("Postgres")
      expect(captured).to include("relational, ACID")
      expect(captured).to include("Redis")
      expect(captured).to include("Your choice")
      # Numbered options live in the same prompt string, not separate ui.info lines.
      expect(captured).to match(/1\.\s+Postgres/)
      expect(captured).to match(/2\.\s+Redis/)
    end

    it "does NOT emit the question or options as separate ui.info lines" do
      allow(ui).to receive(:ask).and_return("1")

      tool.call("question" => "Which datastore?", "options" => options)

      expect(ui).not_to have_received(:info)
    end

    it "resolves a numeric single selection to the chosen label" do
      allow(ui).to receive(:ask).and_return("2")

      result = tool.call("question" => "Which datastore?", "options" => options)

      expect(result).to eq("User selected: Redis")
    end

    it "returns the custom answer when the response is not a valid index" do
      allow(ui).to receive(:ask).and_return("Sqlite please")

      result = tool.call("question" => "Which datastore?", "options" => options)

      expect(result).to eq("User answered: Sqlite please")
    end

    context "with multiple: true" do
      it "includes the multiple-select hint in the combined prompt" do
        captured = nil
        allow(ui).to receive(:ask) { |prompt|
          captured = prompt
          "1,2"
        }

        tool.call("question" => "Which datastores?", "options" => options, "multiple" => true)

        expect(captured).to include("Select multiple numbers")
        expect(captured).to include("Your choice(s)")
      end

      it "resolves multiple numeric selections to a joined label list" do
        allow(ui).to receive(:ask).and_return("1, 2")

        result = tool.call("question" => "Which datastores?", "options" => options, "multiple" => true)

        expect(result).to eq("User selected: Postgres, Redis")
      end
    end
  end

  describe "#call without options (ask_freeform)" do
    it "passes the bare question to ui.ask" do
      captured = nil
      allow(ui).to receive(:ask) { |prompt|
        captured = prompt
        "blue"
      }

      result = tool.call("question" => "Favourite colour?")

      expect(captured).to eq("Favourite colour?")
      expect(result).to eq("User answered: blue")
    end

    it "reports (no response) when the user gives no answer" do
      allow(ui).to receive(:ask).and_return(nil)

      result = tool.call("question" => "Favourite colour?")

      expect(result).to eq("User answered: (no response)")
    end
  end
end
