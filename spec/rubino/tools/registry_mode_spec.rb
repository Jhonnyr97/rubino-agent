# frozen_string_literal: true

# Plan mode MUST pare the LLM-visible tool list down to the read-only
# whitelist. The model can't propose a mutating call if `edit`/`shell`/
# `git` aren't even in the tools array sent on the wire — defence in
# depth: even with a misconfigured approval policy, plan mode is safe.
RSpec.describe Rubino::Tools::Registry do
  before(:all) { Rubino.loader.eager_load }
  before do
    described_class.reset!
    described_class.register_defaults!
  end

  describe ".enabled_tools" do
    context "in :default" do
      it "includes both read-only and mutating tools" do
        names = described_class.enabled_tools.map(&:name)
        # read/grep = read-only; edit/write = mutating. Whether `shell` is
        # enabled depends on test_configuration's defaults — don't pin it
        # here, the point is the mix.
        expect(names).to include("read", "grep", "edit", "write")
      end
    end

    context "in :plan" do
      before { Rubino::Modes.set(:plan) }

      it "exposes only the read-only whitelist" do
        # webfetch/websearch are in the plan whitelist but gated off by the
        # `tools.web: false` default; enable it so this example asserts the
        # full mode whitelist rather than the (independent) config gate.
        Rubino.configuration.set("tools", "web", true)
        names = described_class.enabled_tools.map(&:name).sort
        expect(names).to match_array(Rubino::Modes::READ_ONLY_TOOLS.sort)
      ensure
        Rubino.configuration.set("tools", "web", false)
      end

      it "drops every mutating tool" do
        names = described_class.enabled_tools.map(&:name)
        %w[edit write multi_edit shell ruby apply_patch git github shell_kill].each do |banned|
          expect(names).not_to include(banned), "plan must NOT expose #{banned}"
        end
      end
    end

    context "in :yolo" do
      before { Rubino::Modes.set(:yolo) }

      it "exposes everything (yolo only affects approvals)" do
        default_names = described_class.enabled_tools.map(&:name).sort
        Rubino::Modes.set(:default)
        baseline = described_class.enabled_tools.map(&:name).sort
        expect(default_names).to eq(baseline)
      end
    end
  end
end
