# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Mode::UpdateOperation do
  let(:operation) { described_class.new }
  let(:ui)        { Rubino::UI::Null.new }

  before { Rubino.ui = ui }

  it "switches the active mode and reports the transition" do
    expect(Rubino::Modes.current).to eq(:default)

    status, body = operation.call(make_request(body: { "mode" => "plan" }))

    expect(status).to eq(200)
    expect(body[:mode]).to eq(:plan)
    expect(body[:previous]).to eq(:default)
    expect(body[:description]).to be_a(String).and(satisfy { |s| !s.empty? })
    expect(Rubino::Modes.current).to eq(:plan)
  end

  it "emits a mode_changed UI event so an in-flight SSE stream notices" do
    operation.call(make_request(body: { "mode" => "yolo" }))
    event = ui.messages.find { |m| m[:level] == :mode_changed }
    expect(event).to include(level: :mode_changed, message: :yolo, previous: :default)
  end

  it "raises ValidationError on missing mode" do
    expect { operation.call(make_request(body: {})) }
      .to raise_error(Rubino::ValidationError)
  end

  it "raises ValidationError on an unknown mode (typo)" do
    expect { operation.call(make_request(body: { "mode" => "warp" })) }
      .to raise_error(Rubino::ValidationError)
  end

  it "leaves Modes untouched when validation fails" do
    expect { operation.call(make_request(body: { "mode" => "warp" })) }
      .to raise_error(Rubino::ValidationError)
    expect(Rubino::Modes.current).to eq(:default)
  end
end
