# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::UI::AgentMenu do
  # Default subject is the MAIN-prompt picker (not attached): a pure subagent
  # switcher with no `◂ main session` row. The attached variant (which appends
  # the detach row) is exercised via `attached_menu`.
  subject(:menu) { described_class.new(entries: -> { entries }) }

  let(:attached_menu) { described_class.new(entries: -> { entries }, attached: -> { true }) }

  let(:entry_struct) do
    Struct.new(:id, :subagent, :status, :last_activity, keyword_init: true)
  end
  let(:entries) { [entry(id: "sa_1"), entry(id: "sa_2"), entry(id: "sa_3")] }

  def entry(id:, status: :running, last_activity: "")
    entry_struct.new(id: id, subagent: "explore", status: status, last_activity: last_activity)
  end

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

  it "re-opening an already-open menu preserves the selection (no reset-to-top race)" do
    menu.down # open, sa_1
    menu.down # sa_2
    expect(menu.selected.id).to eq("sa_2")
    menu.open! # a background re-trigger MUST NOT snap the highlight back to sa_1
    expect(menu.selected.id).to eq("sa_2")
  end

  describe "#up! focus hand-off" do
    it "moves the highlight up and returns true while above the top" do
      menu.down # selected sa_1
      menu.down # selected sa_2
      expect(menu.up!).to be(true)
      expect(menu.selected.id).to eq("sa_1")
    end

    it "EXITS the picker at the top — closes itself, returns false, focus to input" do
      menu.down # selected sa_1 (top)
      expect(menu.up!).to be(false)
      expect(menu).not_to be_open # owns its own focus hand-off — no stranded marker
    end

    it "returns false when closed" do
      expect(menu.up!).to be(false)
    end
  end

  it "#down walks past the subagents to the '◂ main' row at the bottom, then clamps (attached)" do
    attached_menu.down # sa_1
    attached_menu.down # sa_2
    attached_menu.down # sa_3
    attached_menu.down # ◂ main (the synthetic bottom row)
    expect(described_class.main_row?(attached_menu.selected)).to be(true)
    attached_menu.down # clamps on main
    expect(described_class.main_row?(attached_menu.selected)).to be(true)
  end

  it "shows a '◂ main session' row at the bottom and accepts it (attached)" do
    attached_menu.down
    rows = attached_menu.rows(80).map { |r| r.gsub(/\e\[[0-9;]*m/, "") }
    expect(rows.any? { |r| r.include?("main session") }).to be(true)
    3.times { attached_menu.down } # to the main row
    expect(described_class.main_row?(attached_menu.accept)).to be(true)
  end

  it "omits the '◂ main session' row at the main prompt (not attached)" do
    menu.down
    rows = menu.rows(80).map { |r| r.gsub(/\e\[[0-9;]*m/, "") }
    expect(rows.none? { |r| r.include?("main session") }).to be(true)
    menu.down # sa_2
    menu.down # sa_3
    menu.down # clamps on the last subagent — no synthetic main row to reach
    expect(menu.selected.id).to eq("sa_3")
    expect(described_class.main_row?(menu.selected)).to be(false)
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
    expect(rows.first).to include("background") # neutral — the picker lists subagents AND shells
    expect(rows.any? { |r| r.include?("sa_1") }).to be(true)
  end
end
