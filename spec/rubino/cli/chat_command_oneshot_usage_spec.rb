# frozen_string_literal: true

# #382 — headless usage must be PERSISTED. On the one-shot path the `runs` table
# got 0 rows (per-run usage was never written), so automation had no window onto
# a scripted turn's token spend. The fix attaches a TurnRecorder around the
# headless turn (the same summed-usage seam the JSON path uses) and writes one
# `runs` row with the real input/output token counts after run! returns.
RSpec.describe Rubino::CLI::ChatCommand do
  let(:db)       { test_database }
  let(:null_ui)  { Rubino::UI::Null.new }
  let(:fake_llm) { FakeLLMAdapter.new }

  # Post-turn auto-extract/distill OFF so the scripted FakeLLM queue is consumed
  # by the conversation alone (same setup as the other e2e one-shot specs).
  let(:config) do
    mem    = Rubino::Config::Defaults.to_hash["memory"].merge("auto_extract" => false)
    skills = Rubino::Config::Defaults.to_hash["skills"].merge("auto_distill" => false)
    test_configuration("memory" => mem, "skills" => skills)
  end

  before do
    allow(Rubino).to receive_messages(database: db, configuration: config)
    allow(Rubino::LLM::RubyLLMAdapter).to receive(:new).and_return(fake_llm)
    allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
    Rubino.ui = null_ui
  end

  describe "persisting per-run usage on the headless path (#382)" do
    it "writes a runs row with NON-ZERO token counts (text mode)" do
      fake_llm.enqueue_text("the answer", input_tokens: 42, output_tokens: 17)

      expect do
        described_class.new("query" => "hi").execute
      rescue SystemExit => e
        raise "expected a clean exit-0 run, got status #{e.status}"
      end.to output(/the answer/).to_stdout

      runs = db.db[:runs].all
      expect(runs.size).to eq(1)
      expect(runs.first[:status]).to eq("completed")
      expect(runs.first[:tokens_input]).to eq(42)
      expect(runs.first[:tokens_output]).to eq(17)
    end

    it "writes a runs row with NON-ZERO token counts (--json mode)" do
      fake_llm.enqueue_text("the answer", input_tokens: 31, output_tokens: 9)

      expect do
        described_class.new("query" => "hi", "json" => true).execute
      rescue SystemExit => e
        raise "expected a clean exit-0 run, got status #{e.status}"
      end.to output(/"type":"result"/).to_stdout

      runs = db.db[:runs].all
      expect(runs.size).to eq(1)
      expect(runs.first[:tokens_input]).to eq(31)
      expect(runs.first[:tokens_output]).to eq(9)
    end
  end
end
