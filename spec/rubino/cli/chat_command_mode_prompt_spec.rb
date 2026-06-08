# frozen_string_literal: true

# The interactive prompt is agent-composer style — `default ❯ ` — not shell.
# Mode is the only live context shown; workspace, git, model, and session
# are printed once at startup in run_interactive. The chip name matches the
# canonical mode label used by /mode and the transition banner (F9).
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new({}) }

  describe "#build_prompt" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    def strip_ansi(s) = s.gsub(/\e\[[0-9;]*m/, "")

    it "[default] prompt in default mode" do
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("default ❯ ")
    end

    it "[plan] prompt in :plan" do
      Rubino::Modes.set(:plan)
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("plan ❯ ")
    ensure
      Rubino::Modes.set(:default)
    end

    it "[yolo] prompt in :yolo" do
      Rubino::Modes.set(:yolo)
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("yolo ❯ ")
    ensure
      Rubino::Modes.set(:default)
    end

    it "no git context in prompt (it's in the startup banner)" do
      Rubino::Modes.set(:yolo)
      system("git init -q -b main && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init")
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("yolo ❯ ")
    end

    it "colours :default dim, :plan cyan, :yolo bold yellow" do
      pastel = Pastel.new(enabled: true)
      cmd.instance_variable_set(:@pastel, pastel)

      # Check that mode_label produces the right colors
      Rubino::Modes.set(:default)
      default_label = cmd.send(:mode_label)
      expect(default_label).to eq(pastel.dim("default"))

      Rubino::Modes.set(:plan)
      plan_label = cmd.send(:mode_label)
      expect(plan_label).to eq(pastel.cyan("plan"))

      Rubino::Modes.set(:yolo)
      yolo_label = cmd.send(:mode_label)
      expect(yolo_label).to eq(pastel.yellow.bold("yolo"))
    ensure
      Rubino::Modes.set(:default)
    end
  end
end