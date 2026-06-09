# frozen_string_literal: true

# Behavioural spec: verifica che l'utente veda in RichTerminal (tramite UI::Null)
# 1. I tool disponibili vengono registrati e trovati
# 2. Lo streaming del testo è visibile chunk per chunk
# 3. Il nome del tool appare prima dell'esecuzione (tool_started)
# 4. Il completamento del tool appare dopo (tool_finished)
# 5. stream_end viene chiamato sia dopo una risposta testuale sia dopo una tool call
# 6. La sequenza corretta degli eventi UI nel caso tool → testo finale
# 7. Il thinking del modello prima di un tool call viene chiuso correttamente

RSpec.describe "Agent behaviour observable from the UI" do
  # ---------------------------------------------------------------------------
  # Setup condiviso
  # ---------------------------------------------------------------------------

  let(:db)       { test_database }
  let(:ui)       { Rubino::UI::Null.new }
  let(:fake_llm) { FakeLLMAdapter.new }
  let(:config)   { test_configuration }
  let(:event_bus) { Rubino::Interaction::EventBus.new }

  let(:session) do
    Rubino::Session::Repository.new.create(source: "test", model: "fake-model")
  end

  let(:message_store) { Rubino::Session::Store.new }
  let(:budget)        { Rubino::Agent::IterationBudget.new(config: config) }

  let(:approval_policy) { Rubino::Security::ApprovalPolicy.new(config: config) }

  let(:tool_executor) do
    Rubino::Agent::ToolExecutor.new(
      registry: Rubino::Tools::Registry,
      approval_policy: approval_policy,
      ui: ui,
      config: config
    )
  end

  before do
    allow(Rubino).to receive(:database).and_return(db)
    Rubino::Tools::Registry.reset!
  end

  after { Rubino::Tools::Registry.reset! }

  def build_loop(llm: fake_llm)
    Rubino::Agent::Loop.new(
      session: session,
      llm_adapter: llm,
      tool_executor: tool_executor,
      message_store: message_store,
      budget: budget,
      ui: ui,
      event_bus: event_bus,
      config: config
    )
  end

  def user_messages(text = "ciao")
    [{ role: "user", content: text }]
  end

  # Helper: tutti gli eventi UI di un certo livello
  def ui_events(level) = ui.messages.select { |m| m[:level] == level }
  def ui_event_names(level) = ui_events(level).map { |m| m[:message] }

  # ---------------------------------------------------------------------------
  # 1. Tool registrati e trovati
  # ---------------------------------------------------------------------------

  describe "1. Tool disponibili" do
    it "i tool di default vengono registrati nel Registry" do
      Rubino::Tools::Registry.register_defaults!
      nomi = Rubino::Tools::Registry.all.map(&:name)
      expect(nomi).to include("read", "write", "edit", "multi_edit", "grep", "glob", "git", "shell", "shell_output",
                              "shell_kill")
    end

    it "un tool registrato viene trovato per nome" do
      Rubino::Tools::Registry.register(Rubino::Tools::GlobTool.new)
      expect(Rubino::Tools::Registry.find("glob")).to be_a(Rubino::Tools::GlobTool)
    end

    it "enabled_tools non restituisce tool disabilitati nel config" do
      Rubino::Tools::Registry.register_defaults!
      # web ships OFF by default (sandboxed VM) — use it as the disabled probe.
      # shell is now ON by default (the VM is the sandbox; it stays gated by
      # security.require_confirmation_for_shell), so it can't be the example.
      nomi_abilitati = Rubino::Tools::Registry.enabled_tools.map(&:name)
      expect(nomi_abilitati).not_to include("webfetch")
      expect(nomi_abilitati).to include("shell")
    end

    it "enabled_tools restituisce tool senza config esplicita come abilitati (opt-out)" do
      Rubino::Tools::Registry.register(Rubino::Tools::GlobTool.new)
      Rubino::Tools::Registry.register(Rubino::Tools::GrepTool.new)
      nomi = Rubino::Tools::Registry.enabled_tools.map(&:name)
      expect(nomi).to include("glob", "grep")
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Streaming testo visibile chunk per chunk
  # ---------------------------------------------------------------------------

  describe "2. Streaming del testo" do
    let(:streaming_config) do
      test_configuration(
        "streaming" => { "enabled" => true, "transport" => "off",
                         "edit_interval" => 0.3, "buffer_threshold" => 40, "cursor" => " ▉" },
        "display" => { "streaming" => true, "show_reasoning" => false,
                       "language" => "en",
                       "runtime_footer" => { "enabled" => false },
                       "interim_assistant_messages" => false }
      )
    end

    def build_streaming_loop
      Rubino::Agent::Loop.new(
        session: session, llm_adapter: fake_llm, tool_executor: tool_executor,
        message_store: message_store,
        budget: Rubino::Agent::IterationBudget.new(config: streaming_config),
        ui: ui, event_bus: event_bus, config: streaming_config
      )
    end

    it "emette almeno un chunk :stream per una risposta testuale" do
      fake_llm.enqueue_text("ciao mondo")
      build_streaming_loop.run(messages: user_messages, tools: [])

      expect(ui_events(:stream)).not_to be_empty
    end

    it "i chunk ricomposti formano il testo completo" do
      fake_llm.enqueue_text("ciao mondo")
      build_streaming_loop.run(messages: user_messages, tools: [])

      testo = ui_events(:stream).map { |m| m[:message] }.join
      expect(testo).to eq("ciao mondo")
    end

    it "emette :stream_end alla fine della risposta testuale" do
      fake_llm.enqueue_text("testo finale")
      build_streaming_loop.run(messages: user_messages, tools: [])

      expect(ui_events(:stream_end)).not_to be_empty
    end

    it "lo stream viene chiuso prima del riepilogo del turno" do
      fake_llm.enqueue_text("risposta")
      build_streaming_loop.run(messages: user_messages, tools: [])

      # Loop now ends every turn with a `↳ turn · …` note so the cost
      # stays visible. The stream must be closed first; otherwise the
      # note would land on the same line as the streamed text.
      levels = ui.messages.map { |m| m[:level] }
      expect(levels.last).to eq(:note)
      expect(levels[-2]).to eq(:stream_end)
      expect(ui.messages.last[:message]).to include("↳ turn · ")
    end
  end

  # ---------------------------------------------------------------------------
  # 3. tool_started — il nome del tool appare prima dell'esecuzione
  # ---------------------------------------------------------------------------

  describe "3. Visibilità del tool prima dell'esecuzione" do
    let(:echo_tool) do
      Class.new(Rubino::Tools::Base) do
        def name        = "echo"
        def description = "Restituisce l'input"
        def input_schema = { type: "object", properties: { text: { type: "string" } }, required: ["text"] }
        def risk_level  = :low
        def call(args)  = "eco: #{args["text"]}"
      end.new
    end

    before { Rubino::Tools::Registry.register(echo_tool) }

    it "emette :tool_started con il nome corretto prima dell'esecuzione" do
      fake_llm.enqueue_tool_call("echo", { "text" => "ping" })
      fake_llm.enqueue_text("fatto")
      build_loop.run(messages: user_messages, tools: [])

      expect(ui_event_names(:tool_started)).to include("echo")
    end

    it "tool_started precede tool_finished nella sequenza UI" do
      fake_llm.enqueue_tool_call("echo", { "text" => "x" })
      fake_llm.enqueue_text("ok")
      build_loop.run(messages: user_messages, tools: [])

      ui.messages.each_with_index.filter_map do |m, i|
        i if %i[tool_started tool_finished].include?(m[:level])
      end
      started_idx  = ui.messages.index { |m| m[:level] == :tool_started }
      finished_idx = ui.messages.index { |m| m[:level] == :tool_finished }

      expect(started_idx).to be < finished_idx
    end

    it "emette :tool_started una volta per ogni tool call" do
      fake_llm.enqueue_tool_calls([["echo", { "text" => "a" }], ["echo", { "text" => "b" }]])
      fake_llm.enqueue_text("finito")
      build_loop.run(messages: user_messages, tools: [])

      expect(ui_events(:tool_started).size).to eq(2)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. tool_finished — il completamento è visibile con preview del risultato
  # ---------------------------------------------------------------------------

  describe "4. Visibilità del completamento del tool" do
    let(:upper_tool) do
      Class.new(Rubino::Tools::Base) do
        def name        = "upper"
        def description = "Converte in maiuscolo"
        def input_schema = { type: "object", properties: { text: { type: "string" } }, required: ["text"] }
        def risk_level  = :low
        def call(args)  = args["text"].upcase
      end.new
    end

    before { Rubino::Tools::Registry.register(upper_tool) }

    it "emette :tool_finished con il nome del tool" do
      fake_llm.enqueue_tool_call("upper", { "text" => "hello" })
      fake_llm.enqueue_text("ok")
      build_loop.run(messages: user_messages, tools: [])

      expect(ui_event_names(:tool_finished)).to include("upper")
    end

    it "emette :tool_finished una volta per ogni tool call" do
      fake_llm.enqueue_tool_call("upper", { "text" => "a" })
      fake_llm.enqueue_tool_call("upper", { "text" => "b" })
      fake_llm.enqueue_text("fatto")
      build_loop.run(messages: user_messages, tools: [])

      expect(ui_events(:tool_finished).size).to eq(2)
    end
  end

  # ---------------------------------------------------------------------------
  # 5. stream_end chiamato correttamente — anche dopo una tool call
  # ---------------------------------------------------------------------------

  describe "5. stream_end chiamato nei momenti giusti" do
    let(:noop_tool) do
      Class.new(Rubino::Tools::Base) do
        def name        = "noop"
        def description = "Non fa nulla"
        def input_schema = { type: "object", properties: {}, required: [] }
        def risk_level  = :low
        def call(_)     = "ok"
      end.new
    end

    before { Rubino::Tools::Registry.register(noop_tool) }

    it "stream_end viene emesso almeno una volta per una risposta testuale semplice" do
      fake_llm.enqueue_text("ciao")
      build_loop.run(messages: user_messages, tools: [])

      expect(ui_events(:stream_end).size).to be >= 1
    end

    it "stream_end viene emesso dopo il ciclo tool_call → risposta finale" do
      fake_llm.enqueue_tool_call("noop", {})
      fake_llm.enqueue_text("risposta finale")
      build_loop.run(messages: user_messages, tools: [])

      expect(ui_events(:stream_end).size).to be >= 1
    end

    it "stream_end arriva dopo tool_finished nella sequenza UI" do
      fake_llm.enqueue_tool_call("noop", {})
      fake_llm.enqueue_text("fine")
      build_loop.run(messages: user_messages, tools: [])

      finished_idx   = ui.messages.rindex { |m| m[:level] == :tool_finished }
      stream_end_idx = ui.messages.rindex { |m| m[:level] == :stream_end }

      expect(stream_end_idx).to be > finished_idx
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Sequenza completa degli eventi UI: tool → testo finale
  # ---------------------------------------------------------------------------

  describe "6. Sequenza completa degli eventi UI" do
    let(:counter_tool) do
      Class.new(Rubino::Tools::Base) do
        def name        = "counter"
        def description = "Conta"
        def input_schema = { type: "object", properties: {}, required: [] }
        def risk_level  = :low
        def call(_)     = "contato"
      end.new
    end

    before { Rubino::Tools::Registry.register(counter_tool) }

    it "la sequenza di livelli UI è quella attesa per tool → risposta" do
      fake_llm.enqueue_tool_call("counter", {})
      fake_llm.enqueue_text("ecco il risultato")
      build_loop.run(messages: user_messages, tools: [])

      livelli = ui.messages.map { |m| m[:level] }

      # tool_started deve comparire
      expect(livelli).to include(:tool_started)
      # tool_finished deve comparire
      expect(livelli).to include(:tool_finished)
      # stream_end deve comparire
      expect(livelli).to include(:stream_end)

      # Ordine: tool_started < tool_finished < stream_end
      ts = livelli.index(:tool_started)
      tf = livelli.index(:tool_finished)
      se = livelli.rindex(:stream_end)

      expect(ts).to be < tf
      expect(tf).to be < se
    end

    it "con due tool call la sequenza mantiene l'ordine per ciascuno" do
      fake_llm.enqueue_tool_call("counter", {})
      fake_llm.enqueue_tool_call("counter", {})
      fake_llm.enqueue_text("tutto fatto")
      build_loop.run(messages: user_messages, tools: [])

      livelli = ui.messages.map { |m| m[:level] }
      avvii      = livelli.each_index.select { |i| livelli[i] == :tool_started }
      completati = livelli.each_index.select { |i| livelli[i] == :tool_finished }

      expect(avvii.size).to eq(2)
      expect(completati.size).to eq(2)
      # ogni avvio precede il relativo completamento
      avvii.zip(completati).each do |s, f|
        expect(s).to be < f
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Thinking del modello prima di un tool call — stream chiuso correttamente
  # ---------------------------------------------------------------------------

  describe "7. Thinking/preamble del modello prima di tool call" do
    let(:noop_tool) do
      Class.new(Rubino::Tools::Base) do
        def name        = "noop"
        def description = "Non fa nulla"
        def input_schema = { type: "object", properties: {}, required: [] }
        def risk_level  = :low
        def call(_)     = "ok"
      end.new
    end

    before { Rubino::Tools::Registry.register(noop_tool) }

    it "stream_end viene emesso anche quando il modello ha thinking text + tool call" do
      # Il modello emette del testo di preamble prima del tool call
      fake_llm.enqueue_tool_call("noop", {}, content: "Analizzo i dati...")
      fake_llm.enqueue_text("Analisi completata.")
      build_loop.run(messages: user_messages, tools: [])

      expect(ui_events(:stream_end)).not_to be_empty
    end

    it "stream_end è chiamato sia dopo thinking text sia dopo risposta finale" do
      # Regression: in passato close_intermediate_stream non veniva chiamata
      # tra il preamble e il tool call, lasciando lo stream "aperto".
      # Verifichiamo via UI::Null che stream_end appaia ad ogni chiusura.
      fake_llm.enqueue_tool_call("noop", {}, content: "pensiero intermedio")
      fake_llm.enqueue_text("risposta finale")

      build_loop.run(messages: user_messages, tools: [])

      # Almeno due stream_end: uno dopo il thinking, uno dopo la risposta finale.
      expect(ui_events(:stream_end).size).to be >= 2
    end
  end
end
