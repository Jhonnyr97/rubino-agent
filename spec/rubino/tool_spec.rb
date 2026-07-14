# frozen_string_literal: true

RSpec.describe Rubino::Tool do
  # ── Auto-registration ────────────────────────────────────────────────

  describe "auto-registration" do
    prepend_before do
      @_saved_tool_subclasses = described_class.instance_variable_get(:@_tool_subclasses).dup
    end

    before { described_class._clear_pending_registrations! }

    after do
      described_class.instance_variable_set(:@_tool_subclasses, @_saved_tool_subclasses)
      Rubino::Tools::Registry.reset!
      Rubino::Tools::Registry.register_defaults!
    end

    it "collects named subclasses and registers them on finalize_registrations!" do
      allow(Rubino::Tools::Registry).to receive(:register)

      # Define via eval so Ruby assigns a name BEFORE the Class.new block
      # finishes (inherited fires INSIDE the block, so stub_const is too late).
      eval <<~RUBY, binding, __FILE__, __LINE__ + 1
        class TestAutoRegEvalTool < Rubino::Tool
          def name
            "test_auto_eval"
          end
        end
      RUBY

      # inherited fires BEFORE the class body — it only collects the
      # subclass.  Registration happens later, after the body is defined.
      described_class.finalize_registrations!

      expect(Rubino::Tools::Registry).to have_received(:register)
        .with(an_instance_of(TestAutoRegEvalTool))
    end

    it "does NOT register an abstract! named class" do
      eval <<~RUBY, binding, __FILE__, __LINE__ + 1
        class TestAbstractRegEvalTool < Rubino::Tool
          abstract!
          def name
            "test_abstract_eval"
          end
        end
      RUBY

      described_class.finalize_registrations!

      expect(Rubino::Tools::Registry.find("test_abstract_eval")).to be_nil
    end

    it "does NOT register Rubino::Tool itself (it is abstract!)" do
      expect(Rubino::Tools::Registry.find("tool")).to be_nil
    end

    it "does NOT register anonymous subclasses (test fixtures)" do
      _klass = Class.new(described_class) do
        define_method(:name) { "test_anon_skip" }
      end
      # Anonymous — klass.name is nil, so inherited skips registration.

      expect(Rubino::Tools::Registry.find("test_anon_skip")).to be_nil
    end

    # ITEM 3: prove the reload path — after Registry.reset! + re-finalize,
    # a previously-registered named subclass reappears (no ObjectSpace scan).
    it "re-registers named subclasses after Registry.reset! + finalize_registrations!" do
      eval <<~RUBY, binding, __FILE__, __LINE__ + 1
        class TestReloadEvalTool < Rubino::Tool
          def name
            "test_reload_eval"
          end
        end
      RUBY

      described_class.finalize_registrations!
      expect(Rubino::Tools::Registry.find("test_reload_eval")).not_to be_nil

      Rubino::Tools::Registry.reset!
      expect(Rubino::Tools::Registry.find("test_reload_eval")).to be_nil

      # Re-finalize — the append-only list replays, no ObjectSpace needed.
      described_class.finalize_registrations!
      expect(Rubino::Tools::Registry.find("test_reload_eval")).not_to be_nil
    end

  end

  # ── Inheritance footgun fix ──────────────────────────────────────────
  # base.rb:16-21: @tool_security does NOT inherit in plain Ruby.
  # Rubino::Tool copies them down in inherited.

  describe "inheritance footgun fix" do
    it "child keeps parent's risk level" do
      parent = Class.new(described_class) do
        risk :medium
        describe "parent"
      end
      stub_const("FootgunParent", parent)

      child = Class.new(parent) do
        define_method(:name) { "test_footgun_child" }
      end
      stub_const("FootgunChild", child)

      instance = child.new
      expect(instance.risk_level).to eq(:medium)
      expect(instance.risky?).to be(true)
    ensure
      Rubino::Tools::Registry.unregister("test_footgun_child")
    end

    it "child keeps parent's redaction profile" do
      parent = Class.new(described_class) do
        redaction :none
        describe "parent"
      end
      stub_const("FootgunRedParent", parent)

      child = Class.new(parent) do
        define_method(:name) { "test_footgun_red" }
      end
      stub_const("FootgunRedChild", child)

      expect(child.redaction_profile).to eq(:none)
    ensure
      Rubino::Tools::Registry.unregister("test_footgun_red")
    end

    it "child keeps parent's image_params" do
      parent = Class.new(described_class) do
        image :img, "an image"
        describe "parent"
      end
      stub_const("FootgunImgParent", parent)

      child = Class.new(parent) do
        define_method(:name) { "test_footgun_img" }
      end
      stub_const("FootgunImgChild", child)

      expect(child.image_params).to include(:img)
    ensure
      Rubino::Tools::Registry.unregister("test_footgun_img")
    end
  end

  # ── Result helpers ───────────────────────────────────────────────────

  describe "#ok" do
    let(:tool) { Class.new(described_class) { abstract! }.new }

    it "returns a Hash with :output" do
      result = tool.ok("done")
      expect(result).to be_a(Hash)
      expect(result[:output]).to eq("done")
    end

    it "passes through :metrics" do
      result = tool.ok("done", metrics: "42 lines · 0.1s")
      expect(result[:metrics]).to eq("42 lines · 0.1s")
    end

    it "sets body_kind to :diff when diff: given" do
      result = tool.ok("patched", diff: "+added line")
      expect(result[:body]).to eq("+added line")
      expect(result[:body_kind]).to eq(:diff)
    end

    it "sets body_kind to :json when json: given" do
      result = tool.ok("data", json: { key: "val" })
      expect(result[:body]).to include('"key"')
      expect(result[:body_kind]).to eq(:json)
    end

    it "passes through :artifact and :label" do
      art = { path: "/tmp/x.png", filename: "x.png", content_type: "image/png", byte_size: 42 }
      result = tool.ok("attached", artifact: art, label: "my-label")
      expect(result[:artifact]).to eq(art)
      expect(result[:label]).to eq("my-label")
    end

    it "returns empty string output when no text given" do
      result = tool.ok
      expect(result[:output]).to eq("")
    end
  end

  describe "#error" do
    let(:tool) { Class.new(described_class) { abstract! }.new }

    it "returns a Hash with 'Error:'-prefixed output" do
      result = tool.error("something went wrong")
      expect(result[:output]).to eq("Error: something went wrong")
    end

    it "passes through :code as :error_code" do
      result = tool.error("bad path", code: :outside_workspace)
      expect(result[:error_code]).to eq(:outside_workspace)
    end

    it "produces output the ToolExecutor recognises as errorish" do
      result = tool.error("fail")
      expect(result[:output]).to match(/\AError[:\s]/)
    end
  end

  # ── Bare String return ───────────────────────────────────────────────

  describe "bare String return" do
    it "still works unchanged" do
      klass = Class.new(described_class) do
        abstract!
        describe "bare"
        define_method(:name) { "test_bare" }
        define_method(:execute) { |**_kwargs| "plain string result" }
      end
      tool = klass.new

      result = tool.call({})
      expect(result).to eq("plain string result")
    end
  end

  # ── risk / redaction macros ──────────────────────────────────────────

  describe "risk macro" do
    it "defaults to :low" do
      klass = Class.new(described_class) do
        abstract!
        describe "default"
        define_method(:name) { "test_risk_default" }
      end
      expect(klass.new.risk_level).to eq(:low)
    end

    it "synthesises ToolSecurity for :medium" do
      klass = Class.new(described_class) do
        abstract!
        risk :medium
        describe "medium risk"
        define_method(:name) { "test_risk_med" }
      end
      tool = klass.new
      expect(tool.risk_level).to eq(:medium)
      expect(tool.risky?).to be(true)
    end

    it "synthesises ToolSecurity for :high" do
      klass = Class.new(described_class) do
        abstract!
        risk :high
        describe "high risk"
        define_method(:name) { "test_risk_high" }
      end
      tool = klass.new
      expect(tool.risk_level).to eq(:high)
      expect(tool.risky?).to be(true)
    end

    it "supports require_read via risk macro" do
      klass = Class.new(described_class) do
        abstract!
        risk :medium, require_read: true
        describe "read-gated"
        define_method(:name) { "test_risk_read" }
      end
      expect(klass.new.security.require_read).to be(true)
    end

    it "supports require_overwrite_guard via risk macro" do
      klass = Class.new(described_class) do
        abstract!
        risk :medium, require_overwrite_guard: true
        describe "overwrite-gated"
        define_method(:name) { "test_risk_owg" }
      end
      expect(klass.new.security.require_overwrite_guard).to be(true)
    end

    it "supports allow_widening via risk macro" do
      klass = Class.new(described_class) do
        abstract!
        risk :medium, allow_widening: true
        describe "widening"
        define_method(:name) { "test_risk_widen" }
      end
      expect(klass.new.security.allow_widening).to be(true)
    end
  end

  # ── Presentation DSL ──────────────────────────────────────────────────

  describe "presentation DSL" do
    it "defaults to ToolPresentationCLI with no declaration" do
      klass = Class.new(described_class) do
        abstract!
        describe "no pres"
        define_method(:name) { "test_pres_default" }
      end
      expect(klass.new.presentation).to be_a(Rubino::Tools::ToolPresentationCLI)
      expect(klass.new.presentation.stream_params?).to be(false)
      expect(klass.new.presentation.body_kind).to eq(:plain)
    end

    it "accepts a class (backward compat)" do
      inner = Class.new(Rubino::Tools::ToolPresentation) do
        define_method(:stream_params?) { true }
        define_method(:body_kind) { :diff }
      end

      klass = Class.new(described_class) do
        abstract!
        presentation inner
        describe "class pres"
        define_method(:name) { "test_pres_class" }
      end
      pres = klass.new.presentation
      expect(pres.stream_params?).to be(true)
      expect(pres.body_kind).to eq(:diff)
    end

    it "synthesises from a block: stream_params + body_kind" do
      klass = Class.new(described_class) do
        abstract!
        presentation do
          stream_params true
          body_kind :diff
        end
        describe "block pres"
        define_method(:name) { "test_pres_block" }
      end
      pres = klass.new.presentation
      expect(pres.stream_params?).to be(true)
      expect(pres.body_kind).to eq(:diff)
    end

    it "synthesises from a block: preview_lines" do
      klass = Class.new(described_class) do
        abstract!
        presentation do
          preview_lines nil
        end
        describe "preview_lines nil"
        define_method(:name) { "test_pres_plines" }
      end
      expect(klass.new.presentation.preview_lines).to be_nil
    end

    it "synthesises preview_arguments from a block" do
      klass = Class.new(described_class) do
        abstract!
        presentation do
          preview_arguments do |label, args|
            "#{label}: #{args[:file_path]}"
          end
        end
        describe "preview_args"
        define_method(:name) { "test_pres_pa" }
      end
      result = klass.new.presentation.preview_arguments("edit", { file_path: "foo.rb" })
      expect(result).to eq("edit: foo.rb")
    end

    it "returns nil from preview_arguments when the block returns nil" do
      klass = Class.new(described_class) do
        abstract!
        presentation do
          preview_arguments { |_, _| nil }
        end
        describe "nil pa"
        define_method(:name) { "test_pres_nil_pa" }
      end
      expect(klass.new.presentation.preview_arguments("test", {})).to be_nil
    end

    it "raises ArgumentError when presentation receives neither class nor block" do
      expect do
        Class.new(described_class) do
          abstract!
          presentation
        end
      end.to raise_error(ArgumentError, /requires a class or a block/)
    end
  end

  # ── Image param guards ───────────────────────────────────────────────
  # These mirror vision_tool_spec.rb exactly.

  describe "image param guards" do
    let(:tmp_dir) { Dir.mktmpdir("tool_spec_image") }

    let(:image_tool_class) do
      Class.new(described_class) do
        image :file_path, "path to image"
        describe "image test tool"
        define_method(:name) { "test_iguard" }

        define_method(:execute) do |file_path:, **_kwargs|
          "ok: #{file_path}"
        end
      end
    end

    before do
      Rubino.configuration.set("terminal", "cwd", tmp_dir)
      stub_const("TestImageGuardTool", image_tool_class)
    end

    after do
      Rubino.configuration.set("terminal", "cwd", nil)
      Rubino::Workspace.reset!
      FileUtils.rm_rf(tmp_dir)
      Rubino::Tools::Registry.unregister("test_iguard")
    end

    it "rejects missing file_path (RubyLLM keyword validation)" do
      out = image_tool_class.new.call({})
      expect(out).to include("missing keyword")
    end

    it "rejects non-existent file inside the workspace" do
      out = image_tool_class.new.call("file_path" => File.join(tmp_dir, "missing.png"))
      expect(out).to include("file not found")
    end

    it "denies an out-of-workspace image (r5c NEW-2)" do
      Dir.mktmpdir("sibling-img") do |sibling|
        outside = File.join(sibling, "secret.png")
        File.binwrite(outside, "\x89PNG\r\n\x1A\nfake")

        allow(Rubino::LLM::AuxiliaryClient).to receive(:new) { raise "aux must not be called" }

        result = image_tool_class.new.call("file_path" => outside)
        expect(result).to be_a(Hash)
        expect(result[:error_code]).to eq(:outside_workspace)
        expect(result[:output]).to include("outside your workspace")
      end
    end

    it "rejects a directory" do
      out = image_tool_class.new.call("file_path" => tmp_dir)
      expect(out).to include("not a regular file")
    end

    it "rejects an unsupported extension" do
      path = File.join(tmp_dir, "doc.pdf")
      File.binwrite(path, "%PDF-1.4\nfake")
      out = image_tool_class.new.call("file_path" => path)
      expect(out).to include("unsupported image extension")
    end

    it "rejects a .png-named non-image by content (#579)" do
      spoof = File.join(tmp_dir, "fake_image.png")
      File.write(spoof, "this is plain text, not an image\n")

      allow(Rubino::LLM::AuxiliaryClient).to receive(:new) { raise "aux must not be called" }

      out = image_tool_class.new.call("file_path" => spoof)
      expect(out).to include("not a valid image")
      expect(out).to include("nothing was sent to the vision model")
    end

    it "rejects a truncated/corrupt PNG by content (#579)" do
      corrupt = File.join(tmp_dir, "corrupt.png")
      File.binwrite(corrupt, "\x00\x01\x02not-a-real-png-header")

      allow(Rubino::LLM::AuxiliaryClient).to receive(:new) { raise "aux must not be called" }

      expect(image_tool_class.new.call("file_path" => corrupt)).to include("not a valid image")
    end

    describe "egress kill-switch (#578)" do
      let(:png_path) { File.join(tmp_dir, "img.png") }

      before { File.binwrite(png_path, "\x89PNG\r\n\x1A\nfake-image-bytes") }

      after { Rubino.configuration.set("attachments", "policy", nil) }

      it "refuses when aux_vision_egress is false" do
        Rubino.configuration.set("attachments", "policy", { "aux_vision_egress" => false })

        allow(Rubino::LLM::AuxiliaryClient).to receive(:new) { raise "aux must not be called" }

        out = image_tool_class.new.call("file_path" => png_path)
        expect(out).to include("image egress is disabled by config")
      end

      it "egresses when aux_vision_egress is true (default)" do
        Rubino.configuration.set("attachments", "policy", { "aux_vision_egress" => true })

        response = Rubino::LLM::AdapterResponse.new(
          content: "ok", tool_calls: [], input_tokens: 0, output_tokens: 0, model_id: "fake"
        )
        aux = instance_double(Rubino::LLM::AuxiliaryClient, call: response)
        allow(Rubino::LLM::AuxiliaryClient).to receive(:new).and_return(aux)

        expect(image_tool_class.new.call("file_path" => png_path)).to eq("ok: #{png_path}")
      end
    end

    it "happy path — passes guard and reaches execute" do
      png_path = File.join(tmp_dir, "real.png")
      File.binwrite(png_path, "\x89PNG\r\n\x1A\nfake-image-bytes")

      result = image_tool_class.new.call("file_path" => png_path)
      expect(result).to eq("ok: #{png_path}")
    end
  end

  # ── ask_aux / attach_image helpers ───────────────────────────────────

  describe "#ask_aux" do
    let(:tool) { Class.new(described_class) { abstract! }.new }

    it "delegates to AuxiliaryClient with the right task and messages" do
      response = Rubino::LLM::AdapterResponse.new(
        content: "answer", tool_calls: [], input_tokens: 0, output_tokens: 0, model_id: "fake"
      )
      aux = instance_double(Rubino::LLM::AuxiliaryClient)
      allow(Rubino::LLM::AuxiliaryClient).to receive(:new).and_return(aux)

      expect(aux).to receive(:call) do |task:, messages:, **|
        expect(task).to eq(:vision)
        expect(messages.first[:role]).to eq("user")
        expect(messages.first[:content]).to eq("what is this?")
        response
      end

      result = tool.ask_aux("what is this?")
      expect(result.content).to eq("answer")
    end

    it "passes image_paths when image: given" do
      response = Rubino::LLM::AdapterResponse.new(
        content: "answer", tool_calls: [], input_tokens: 0, output_tokens: 0, model_id: "fake"
      )
      aux = instance_double(Rubino::LLM::AuxiliaryClient)
      allow(Rubino::LLM::AuxiliaryClient).to receive(:new).and_return(aux)

      expect(aux).to receive(:call) do |**kwargs|
        expect(kwargs[:image_paths]).to eq(["/tmp/test.png"])
        response
      end

      tool.ask_aux("what is this?", image: "/tmp/test.png")
    end

    it "accepts explicit task: to override the declared aux" do
      response = Rubino::LLM::AdapterResponse.new(
        content: "summary", tool_calls: [], input_tokens: 0, output_tokens: 0, model_id: "fake"
      )
      aux = instance_double(Rubino::LLM::AuxiliaryClient)
      allow(Rubino::LLM::AuxiliaryClient).to receive(:new).and_return(aux)

      expect(aux).to receive(:call) do |task:, **|
        expect(task).to eq(:compression)
        response
      end

      result = tool.ask_aux("summarize this", task: :compression)
      expect(result.content).to eq("summary")
    end
  end

  describe "#attach_image" do
    let(:tool) { Class.new(described_class) { abstract! }.new }

    it "builds an artifact hash from an existing file path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "photo.png")
        File.binwrite(path, "\x89PNG\r\n\x1A\nfake-bytes-here")

        result = tool.attach_image(path, filename: "photo.png")
        expect(result[:output]).to include("Attached photo.png")
        expect(result[:artifact]).to include(
          filename: "photo.png",
          content_type: "image/png",
          byte_size: a_value > 0
        )
        expect(result[:artifact][:path]).to eq(path)
      end
    end

    it "accepts a custom caption" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "img.jpg")
        File.binwrite(path, "\xFF\xD8\xFF\xE0fake")

        result = tool.attach_image(path, filename: "img.jpg", caption: "Here's the chart")
        expect(result[:output]).to eq("Here's the chart")
      end
    end
  end

  # ── Summary DSL ──────────────────────────────────────────────────────

  describe "summary DSL" do
    it "resolves a key-based summary" do
      klass = Class.new(described_class) do
        abstract!
        summary :command
      end
      spec = klass.resolve_summary
      expect(spec).to be_a(Rubino::Tools::SummarySpec)
      expect(spec.key).to eq(:command)
      expect(spec.block?).to be(false)
    end

    it "resolves a block-based summary" do
      klass = Class.new(described_class) do
        abstract!
        summary { |a| a[:pattern] }
      end
      spec = klass.resolve_summary
      expect(spec).to be_a(Rubino::Tools::SummarySpec)
      expect(spec.block?).to be(true)
      expect(spec.proc.call({ pattern: "TODO" })).to eq("TODO")
    end

    it "resolves summary with relative_to: :workspace" do
      klass = Class.new(described_class) do
        abstract!
        summary :file_path, relative_to: :workspace
      end
      spec = klass.resolve_summary
      expect(spec.relative_to).to eq(:workspace)
    end

    it "inherits parent's summary spec (ancestor-walk)" do
      parent = Class.new(described_class) do
        abstract!
        summary :command
      end
      child = Class.new(parent) do
        abstract!
        define_method(:name) { "child_tool" }
      end
      spec = child.resolve_summary
      expect(spec).to be_a(Rubino::Tools::SummarySpec)
      expect(spec.key).to eq(:command)
    end

    it "allows child to override parent's summary" do
      parent = Class.new(described_class) do
        abstract!
        summary :command
      end
      child = Class.new(parent) do
        abstract!
        summary :file_path
      end
      spec = child.resolve_summary
      expect(spec.key).to eq(:file_path)
    end

    it "returns nil when no summary is declared anywhere in the chain" do
      klass = Class.new(described_class) do
        abstract!
      end
      expect(klass.resolve_summary).to be_nil
    end

    it "acts as a reader when called with no arguments" do
      klass = Class.new(described_class) do
        abstract!
        summary :command
      end
      # Calling summary() with no args returns the resolved spec
      expect(klass.summary).to be_a(Rubino::Tools::SummarySpec)
      expect(klass.summary.key).to eq(:command)
    end
  end
end
