# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::UI::AgentMenu do
  Entry = Struct.new(:id, :subagent, :status, :last_activity, keyword_init: true) do
    def initialize(**) = super
  end

  def entry(id:, status: :running, last_activity: "")
    Entry.new(id: id, subagent: "explore", status: status, last_activity: last_activity)
  end

  let(:entries) { [entry(id: "sa_1"), entry(id: "sa_2"), entry(id: "sa_3")] }
  subject(:menu) { described_class.new(entries: -> { entries }) }

  it "starts closed" do
    expect(menu).not_to be_open
    expect(menu.selected).to be_nil
  end

  it "#down opens the menu from closed, highlighting the first entry" do
    menu.down
    expect(menu).to be_open
    expect(menu.selected.id).to eq("sa_1")
  end

  it "does not open when there are no live entries" do
    empty = described_class.new(entries: -> { [] })
    empty.down
    expect(empty).not_to be_open
  end

  describe "#up! focus hand-off" do
    it "moves the highlight up and returns true while above the top" do
      menu.down # selected sa_1
      menu.down # selected sa_2
      expect(menu.up!).to be(true)
      expect(menu.selected.id).to eq("sa_1")
    end

    it "returns FALSE at the top so the caller can close + return focus to the input" do
      menu.down # selected sa_1 (top)
      expect(menu.up!).to be(false)
      expect(menu.selected.id).to eq("sa_1") # unchanged — caller closes the menu
    end

    it "returns false when closed" do
      expect(menu.up!).to be(false)
    end
  end

  it "#down clamps at the last entry" do
    menu.down # sa_1
    menu.down # sa_2
    menu.down # sa_3
    menu.down # clamps
    expect(menu.selected.id).to eq("sa_3")
  end

  it "#accept returns the selected entry and closes" do
    menu.down
    menu.down
    accepted = menu.accept
    expect(accepted.id).to eq("sa_2")
    expect(menu).not_to be_open
  end

  it "#rows renders the header + a row per shown entry only when open" do
    expect(menu.rows(80)).to eq([])
    menu.down
    rows = menu.rows(80).map { |r| r.gsub(/\e\[[0-9;]*m/, "") }
    expect(rows.first).to include("subagents")
    expect(rows.any? { |r| r.include?("sa_1") }).to be(true)
  end
end
