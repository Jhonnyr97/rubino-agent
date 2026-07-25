# frozen_string_literal: true

# #44: the CustomToolLoader `load`s arbitrary Ruby, so it must ONLY ever read
# from the user's HOME config dir (RUBINO_HOME/tools), NEVER from a project's
# cwd `.rubino/tools`. Otherwise cd-ing into a hostile repo could execute its
# code with zero prompt — the exact risk folder-trust exists to prevent.
RSpec.describe Rubino::Tools::CustomToolLoader do
  describe ".tool_paths" do
    it "is HOME-only — under RUBINO_HOME, never a cwd-relative .rubino/tools" do
      paths = described_class.tool_paths
      expect(paths).to eq([File.join(Rubino.home_path, "tools")])
      expect(paths).not_to include(".rubino/tools")
      expect(paths.none? { |p| p == ".rubino/tools" || p.start_with?(".") }).to be(true)
    end
  end

  describe "#load_all!" do
    it "does NOT load a tool file dropped in the current directory's .rubino/tools" do
      Dir.mktmpdir do |cwd|
        FileUtils.mkdir_p(File.join(cwd, ".rubino", "tools"))
        marker = File.join(cwd, ".rubino", "tools", "evil.rb")
        File.write(marker, "$RUBINO_CTL_CWD_LOADED = true")

        Dir.chdir(cwd) do
          $RUBINO_CTL_CWD_LOADED = false
          described_class.new.load_all!
          expect($RUBINO_CTL_CWD_LOADED).to be(false)
        end
      end
    ensure
      $RUBINO_CTL_CWD_LOADED = nil
    end
  end

  # #610: CustomToolLoader#load_all! is now called by Registry#register_defaults!
  # (right before finalize_registrations!), so both authoring styles below must
  # actually end up in the registry, not just get `load`ed with no effect.
  describe "#load_all! + registration (#610)" do
    prepend_before do
      @_saved_tool_subclasses = Rubino::Tool.instance_variable_get(:@_tool_subclasses).dup
    end

    before { Rubino::Tool._clear_pending_registrations! }

    after do
      Rubino::Tool.instance_variable_set(:@_tool_subclasses, @_saved_tool_subclasses)
      Rubino::Tools::Registry.unregister("test_custom_class_dsl")
      Rubino::Tools::Registry.unregister("test_custom_block_dsl")
    end

    it "registers a class-DSL (`class Foo < Rubino::Tool`) custom tool once finalize_registrations! runs" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "class_dsl.rb"), <<~RUBY)
          class TestCustomClassDslTool < Rubino::Tool
            describe "class-DSL custom tool fixture"
            string :input, "Input text"
            risk :low

            def execute(input: "")
              ok("got: \#{input}")
            end
          end
        RUBY

        described_class.new(paths: [dir]).load_all!

        # `inherited` only COLLECTS the subclass — not registered yet.
        expect(Rubino::Tools::Registry.find("test_custom_class_dsl")).to be_nil

        Rubino::Tool.finalize_registrations!

        tool = Rubino::Tools::Registry.find("test_custom_class_dsl")
        expect(tool).to be_a(TestCustomClassDslTool)
        expect(tool.call({ "input" => "x" })[:output]).to eq("got: x")
      end
    end

    it "registers a block-DSL (`Rubino.define_tool`) custom tool immediately on load, no finalize needed" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "block_dsl.rb"), <<~RUBY)
          Rubino.define_tool do
            name "test_custom_block_dsl"
            description "block-DSL custom tool fixture"
            input_schema type: "object", properties: { input: { type: "string" } }
            risk_level :low

            execute do |args|
              "got: \#{args[:input]}"
            end
          end
        RUBY

        described_class.new(paths: [dir]).load_all!

        tool = Rubino::Tools::Registry.find("test_custom_block_dsl")
        expect(tool).not_to be_nil
        expect(tool.call({ input: "x" })).to eq("got: x")
      end
    end

    it "lets a block-DSL custom tool shadow a built-in name, but a class-DSL one cannot" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "shadow.rb"), <<~RUBY)
          Rubino.define_tool do
            name "glob"
            description "shadows the built-in glob"
            input_schema type: "object", properties: {}
            risk_level :low
            execute { |_args| "shadowed" }
          end
        RUBY

        original = Rubino::Tools::Registry.find("glob")
        described_class.new(paths: [dir]).load_all!
        expect(Rubino::Tools::Registry.find("glob").call({})).to eq("shadowed")
      ensure
        Rubino::Tools::Registry.register(original) if original
      end
    end
  end
end
