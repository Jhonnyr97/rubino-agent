# frozen_string_literal: true

RSpec.describe "rubino update", type: :cli do
  let(:ui) { Rubino::UI::Null.new }

  before do
    Rubino.ui = ui
    stub_const("Rubino::VERSION", "0.3.0")
  end

  def run_update
    Rubino::CLI::Commands.new.update
  end

  context "when installed via gem" do
    before do
      allow(Rubino::UpdateCheck).to receive(:install_method).and_return(:gem)
      allow(Rubino::UpdateCheck).to receive(:clear_cache!)
    end

    it "runs `gem update` via the active interpreter in argv form (no shell)" do
      expect_any_instance_of(Rubino::CLI::Commands)
        .to receive(:system)
        .with(Gem.ruby, "-S", "gem", "update", "rubino-agent")
        .and_return(true)
      allow(Rubino::UpdateCheck).to receive(:installed_gem_version).and_return("0.4.1")
      run_update
    end

    it "reports the new version after a successful update" do
      allow_any_instance_of(Rubino::CLI::Commands).to receive(:system).and_return(true)
      allow(Rubino::UpdateCheck).to receive(:installed_gem_version).and_return("0.4.1")
      expect(ui).to receive(:info).with("rubino is now on v0.4.1 (was v0.3.0).")
      allow(ui).to receive(:status)
      run_update
    end

    it "reports already-up-to-date when the installed version didn't change" do
      allow_any_instance_of(Rubino::CLI::Commands).to receive(:system).and_return(true)
      allow(Rubino::UpdateCheck).to receive(:installed_gem_version).and_return("0.3.0")
      expect(ui).to receive(:info).with("rubino is already up to date (v0.3.0).")
      run_update
    end

    it "warns (not crashes) when gem update fails" do
      allow_any_instance_of(Rubino::CLI::Commands).to receive(:system).and_return(false)
      expect(ui).to receive(:warning).with(/gem update failed/)
      run_update
    end

    it "clears the cache afterwards" do
      allow_any_instance_of(Rubino::CLI::Commands).to receive(:system).and_return(true)
      allow(Rubino::UpdateCheck).to receive(:installed_gem_version).and_return("0.4.1")
      expect(Rubino::UpdateCheck).to receive(:clear_cache!)
      run_update
    end
  end

  context "when installed from source / dev checkout" do
    before do
      allow(Rubino::UpdateCheck).to receive(:install_method).and_return(:source)
      allow(Rubino::UpdateCheck).to receive(:clear_cache!)
    end

    it "prints installer guidance instead of attempting gem update" do
      expect_any_instance_of(Rubino::CLI::Commands).not_to receive(:system)
      expect(ui).to receive(:warning).with(/wasn't installed from RubyGems/)
      allow(ui).to receive(:status)
      run_update
    end
  end
end
