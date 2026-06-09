# frozen_string_literal: true

# Regression: a tool returning binary bytes (e.g. ReadTool on a misdetected
# PDF) used to raise JSON::GeneratorError inside EventStore#append, which
# propagated up through emit_finished and killed the run before the model
# could see a tool error. The fix scrubs invalid UTF-8 at this boundary so
# the event is persisted (with replacement chars) and the run survives.
RSpec.describe Rubino::Run::EventStore do
  subject(:store)  { described_class.new(db: connection.db) }

  let(:connection) { test_database }
  let(:session_id) { SecureRandom.uuid }
  let(:run_id)     { SecureRandom.uuid }

  it "persists a payload containing invalid UTF-8 bytes without raising" do
    bad = (+"prefix \xFF\xFE tail").force_encoding(Encoding::ASCII_8BIT)
    expect do
      store.append(session_id: session_id, run_id: run_id, type: "tool.finished",
                   payload: { output: bad })
    end.not_to raise_error
  end

  it "replaces invalid bytes with ? in the stored JSON" do
    bad = (+"\xFF\xFE").force_encoding(Encoding::ASCII_8BIT)
    store.append(session_id: session_id, run_id: run_id, type: "tool.finished",
                 payload: { output: bad })
    rows = connection.db[:events].where(session_id: session_id).all
    expect(rows.size).to eq(1)
    parsed = JSON.parse(rows.first[:payload_json])
    expect(parsed["output"]).to eq("??")
  end

  it "scrubs nested strings inside arrays and hashes" do
    bad = (+"deep \xC3\x28").force_encoding(Encoding::ASCII_8BIT) # invalid UTF-8 multi-byte
    payload = { tools: [{ name: "read", output: bad }], meta: { error: bad } }
    expect do
      store.append(session_id: session_id, run_id: run_id, type: "tool.finished", payload: payload)
    end.not_to raise_error
    row = connection.db[:events].where(session_id: session_id).first
    parsed = JSON.parse(row[:payload_json])
    expect(parsed["tools"][0]["output"]).to include("deep")
    expect(parsed["meta"]["error"]).to include("deep")
  end

  it "leaves valid UTF-8 strings unchanged" do
    payload = { greeting: "ciao 🌍 español" }
    store.append(session_id: session_id, run_id: run_id, type: "msg",
                 payload: payload)
    row = connection.db[:events].where(session_id: session_id).first
    expect(JSON.parse(row[:payload_json])["greeting"]).to eq("ciao 🌍 español")
  end
end
