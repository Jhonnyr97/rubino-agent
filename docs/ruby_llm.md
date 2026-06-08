# RubyLLM v1.15.0 — Guida Tecnica Approfondita

Gemma Ruby per interfacciamento LLM unificato. Architettura modulare: Provider, Chat, Tool, Connection, streaming con accumulator.

## 1. Architettura

```
RubyLLM (main module)
├── Configuration (global config, provider options)
├── Chat (orchestrator conversazione)
├── Provider (base provider, delegates ai sub-provider)
├── Connection (HTTP Faraday + retry + timeout)
├── Message (singolo messaggio)
├── Tool (definizione + esecuzione)
└── [Providers] OpenAI, Anthropic, Ollama, Gemini, Bedrock, ecc.
```

**Chi fa cosa:**
- `RubyLLM.chat()` istanzia `Chat` (lib/ruby_llm/chat.rb:5-30)
- `Chat#complete()` chiama `@provider.complete()` con payload serializzato (chat.rb:193-210)
- `Provider.complete()` delega a `render_payload()` specifico del provider (provider.rb:38-56)
- `Connection` gestisce HTTP, retry, errori via Faraday middleware (connection.rb:25-48)
- `StreamAccumulator` riassembla chunked response in Message (stream_accumulator.rb:7-30)

**File principali:**
- lib/ruby_llm.rb — init, registrazione provider
- lib/ruby_llm/configuration.rb — config object
- lib/ruby_llm/chat.rb — Chat class
- lib/ruby_llm/connection.rb — HTTP connection
- lib/ruby_llm/provider.rb — base Provider

---

## 2. Configurazione

### Global `RubyLLM.configure`

```ruby
RubyLLM.configure do |config|
  config.default_model = 'gpt-5.4'
  config.request_timeout = 300
  config.max_retries = 3
  config.log_level = Logger::INFO
  config.log_file = $stdout
end
```

**Opzioni globali** (lib/ruby_llm/configuration.rb:25-50):
- `default_model` (default: `'gpt-5.4'`)
- `default_embedding_model` (default: `'text-embedding-3-small'`)
- `default_moderation_model` (default: `'omni-moderation-latest'`)
- `default_image_model` (default: `'gpt-image-1.5'`)
- `request_timeout` (default: `300` sec)
- `max_retries` (default: `3`)
- `retry_interval` (default: `0.1`)
- `retry_backoff_factor` (default: `2`)
- `retry_interval_randomness` (default: `0.5`)
- `logger` (default: `nil`, auto-builds se `nil`)
- `log_file` (default: `$stdout`)
- `log_level` (legge `ENV['RUBYLLM_DEBUG']` → `Logger::DEBUG`, else `Logger::INFO`)
- `log_stream_debug` (legge `ENV['RUBYLLM_STREAM_DEBUG']` == `'true'`)

### Per-Provider Options

Registrati via `Provider.configuration_options` (provider.rb dinamico, vedi esempi):

**OpenAI** (lib/ruby_llm/providers/openai.rb:23-31):
```
openai_api_key (REQUIRED)
openai_api_base (default: 'https://api.openai.com/v1')
openai_organization_id
openai_project_id
openai_use_system_role (bool, default: false → use 'developer' role)
```

**Ollama** (lib/ruby_llm/providers/ollama.rb:15-21):
```
ollama_api_base (REQUIRED)
ollama_api_key (optional)
```

**Anthropic** (pattern simile):
```
anthropic_api_key (REQUIRED)
```

**Gemini, Bedrock, Deepseek, Mistral, GPUStack, XAI, Perplexity, OpenRouter** — ciascuno espone proprie `configuration_options` e `configuration_requirements`.

### Variabili d'ambiente

- `RUBYLLM_DEBUG=1` → `log_level = Logger::DEBUG`
- `RUBYLLM_STREAM_DEBUG=true` → abilita debug stream chunks

---

## 3. Provider OpenAI-compatible (Ollama, LM-Studio, vLLM)

### Setup

```ruby
RubyLLM.configure do |config|
  config.openai_api_base = 'http://localhost:8000'
  config.openai_api_key = 'dummy' # spesso non serve
end

chat = RubyLLM.chat(model: 'llama2', provider: :ollama, assume_model_exists: true)
```

**Key distinctions:**

1. **`assume_model_exists: true`** — bypassa validazione modello vs registry (Models.resolve line 116-130)
   - Richiede `provider` esplicito
   - Crea `Model::Info.default(model_id, provider_slug)` on-the-fly

2. **URL format** — POST a `/chat/completions` (openai.rb:8)
   - payload standard OpenAI: `{model, messages, tools, stream, temperature, ...}`

3. **Role formatting**:
   - OpenAI stock: `role: 'system'` se `openai_use_system_role = true`, else `'developer'`
   - Ollama: sempre `role.to_s` (ollama/chat.rb:17)
   - Impatto: system prompt arriva come `{'role': 'developer', 'content': '...'}`

4. **`openai_api_base` override**:
   - Ollama: `@config.ollama_api_base` → Ollama#api_base
   - Generico OpenAI-compat: usa `openai_api_base` (openai.rb:12)

---

## 4. Chat API

### Creazione

```ruby
chat = RubyLLM.chat(model: 'gpt-4', provider: :openai)
# oppure
chat = RubyLLM.chat(model: 'claude-3-5-sonnet-20241022', provider: :anthropic)
```

Constructor: `Chat#initialize(model:, provider:, assume_model_exists:, context:)` (chat.rb:9-32)

### Builder chain (fluent interface)

```ruby
chat
  .with_model('gpt-4')
  .with_instructions('You are a helpful assistant.')
  .with_temperature(0.7)
  .with_tool(MyTool)
  .with_tools(Tool1, Tool2, replace: true)
  .with_schema(MySchema)
  .with_params(extra_param: 'value')
  .with_headers('X-Custom' => 'header')
  .with_thinking(effort: 'high')
  .ask("What's the weather?")
```

**Metodi:**

- **`with_model(model_id, provider:, assume_exists:)`** (chat.rb:62-66)
  - Risolve modello via `Models.resolve()`, istanzia provider
  - Setta `@model`, `@provider`, `@connection`

- **`with_instructions(text, append: false, replace: nil)`** (chat.rb:39-48)
  - `append: false` → replace prima system message
  - `append: true` → aggiungi a system messages

- **`with_temperature(temperature)`** (chat.rb:68-71)
  - Setta `@temperature`, provider può normalizzare (es. OpenAI::Temperature.normalize)

- **`with_tool(tool, choice:, calls:)`** (chat.rb:51-57)
  - tool: classe o istanza Tool
  - `@tools[tool.name.to_sym] = tool_instance`
  - `choice: :auto|:none|:required|<tool_name>` — tool_choice
  - `calls: :many|:one` — parallel_tool_calls

- **`with_tools(*tools, replace:, choice:, calls:)`** (chat.rb:59-63)
  - `replace: true` → pulisci @tools prima

- **`with_schema(schema)`** (chat.rb:80-88)
  - Accetta classe, istanza, o hash JSON Schema
  - Normalizza via `normalize_schema_payload()` → `{name, schema, strict, description}`

- **`with_params(**params)`** — aggiungi al payload richiesta

- **`with_headers(**headers)`** — aggiungi custom HTTP headers

- **`with_thinking(effort:, budget:)`** (chat.rb:73-77)
  - `effort: 'low'|'medium'|'high'` (provider-specific)

- **`ask(message, with:)`** (chat.rb:34-37)
  - Aggiungi user message, chiama `complete()`
  - `with:` → attachments

- **`complete(&block)`** (chat.rb:193-218)
  - Chiama `@provider.complete()`
  - Se block dato → streaming
  - Se response contiene tool_calls → `handle_tool_calls()` in loop
  - Ritorna Message finale o risposta tool

---

## 5. Tool API

### Definizione classica (DSL)

```ruby
class WeatherTool < RubyLLM::Tool
  description 'Fetch weather for a location'
  
  param :location, type: 'string', desc: 'City name', required: true
  param :unit, type: 'string', desc: 'C or F', required: false

  def execute(location:, unit: 'C')
    # logica tool
    { temperature: 22, unit: unit }
  end
end
```

**Generazione schema param:**
- `param(name, type:, desc:, required:)` → `Tool.parameters` hash
- `Tool#params_schema` → `SchemaDefinition.from_parameters()` → JSON Schema (tool.rb:90-112)

### Definizione avanzata (override)

```ruby
class CustomTool < RubyLLM::Tool
  def name
    'custom_action'
  end

  def description
    'Do something custom'
  end

  def params_schema
    {
      type: 'object',
      properties: {
        field: { type: 'string' }
      },
      required: ['field'],
      additionalProperties: false,
      strict: true
    }
  end

  def execute(field:)
    { result: "processed #{field}" }
  end
end
```

**Schema con `params` DSL:**

```ruby
class AdvancedTool < RubyLLM::Tool
  params do |schema|
    schema.object do
      schema.string :name, required: true
      schema.number :age
    end
  end

  def execute(name:, age: nil)
    # ...
  end
end
```

### Serializzazione per API

`Providers::OpenAI::Tools#tool_for(tool)` (openai/tools.rb:26-40):
```ruby
{
  type: 'function',
  function: {
    name: tool.name,
    description: tool.description,
    parameters: tool.params_schema  # JSON Schema
  }
}
```

Payload chat:
```json
{
  "model": "gpt-4",
  "messages": [...],
  "tools": [
    { "type": "function", "function": { "name": "weather", "description": "...", "parameters": {...} } }
  ],
  "tool_choice": "auto"
}
```

### Tool choice

```ruby
chat.with_tool(MyTool, choice: :auto)    # auto-select tool
chat.with_tool(MyTool, choice: :required) # force tool call
chat.with_tool(MyTool, choice: MyTool)    # force specific tool
```

Validazione: (chat.rb:248-256)
- `:auto`, `:none`, `:required`, o nome tool (symbol)

### Parallel tool calls

```ruby
chat.with_tools(Tool1, Tool2, calls: :many)  # parallel
chat.with_tools(Tool1, Tool2, calls: :one)   # sequential
```

Serializzato: `payload[:parallel_tool_calls] = (calls == :many)` (openai/chat.rb:24)

---

## 6. Streaming

### Block pattern

```ruby
chat.ask("Say something long") do |chunk|
  puts chunk.content  # incrementale
  # chunk è RubyLLM::Chunk (extends Message)
end
```

**Flow:**
1. `Chat#complete(&block)` passa block a `@provider.complete()`
2. Provider chiama `stream_response(@connection, payload, headers, &block)` (provider.rb:48)
3. `Streaming#stream_response()` istanzia `StreamAccumulator`, posts con streaming (streaming.rb:7-22)
4. On-data handler: richiama `block.call(chunk)` per ogni delta (streaming.rb:27-30)

### Chunk content

`Chunk` = sottoclasse `Message` (chunk.rb:1-6). Accede a:
- `chunk.content` — stringa delta
- `chunk.thinking` — Thinking object con `text` (se thinking stream)
- `chunk.tool_calls` — hash ToolCall (frammentati)
- `chunk.input_tokens`, `chunk.output_tokens` — token count parziali

### StreamAccumulator

Riassembla stream pieces in completa Message:

```ruby
accumulator = StreamAccumulator.new

# Per ogni chunk ricevuto:
accumulator.add(chunk)

# Al termine stream:
message = accumulator.to_message(response)
```

**Internals** (stream_accumulator.rb):
- `@content` — accumula text content
- `@thinking_text` — accumula thinking (estrae da `<think>` tags)
- `@tool_calls` — hash ToolCall, riassembla JSON args frammentati (line 65-87)
- `count_tokens()` — prende ultimi token count dal chunk

**Edge case: tool_calls in streaming**
Tool arguments arrivano come JSON string frammentata:
```
Chunk 1: tool_calls[0].arguments = '{"na'
Chunk 2: tool_calls[0].arguments = 'me": "John'
Chunk 3: tool_calls[0].arguments = '"}'
```

Accumulator concatena (line 80):
```ruby
existing.arguments << fragment
```

Poi `tool_calls_from_stream()` fa JSON.parse() a fine stream (line 48-60).

---

## 7. Tool execution loop

**Automatico in `Chat#complete()`:**

```ruby
if response.tool_call?
  handle_tool_calls(response, &)
else
  response
end
```

**`handle_tool_calls()` flow** (chat.rb:228-250):

1. Per ogni tool_call in response:
   ```ruby
   response.tool_calls.each_value do |tool_call|
     result = execute_tool(tool_call)  # chiama tool.call(arguments)
     add_message(role: :tool, content: result, tool_call_id: tool_call.id)
   end
   ```

2. Se nessun halt: richiama `complete(&)` ricorsivamente → loop continua finché niente più tool_calls

3. `halt()` interrompe loop:
   ```ruby
   def execute(...)
     return halt("Stop here") if condition
   end
   ```

**Tool execution** (chat.rb:251-265):
```ruby
def execute_tool(tool_call)
  tool = tools[tool_call.name.to_sym]
  args = tool_call.arguments  # già parsed JSON hash
  tool.call(args)  # Tool#call normalizza + chiama execute(**args)
end
```

Tool#call (tool.rb:105-115):
- Normalizza args a symbol keys
- Valida keyword signature di execute()
- Chiama `execute(**normalized_args)`
- Logga call e risultato

---

## 8. Messages, history, persistence

### Message structure

```ruby
RubyLLM::Message.new(
  role: :system|:user|:assistant|:tool,
  content: 'text or Content object',
  tool_calls: { 'id' => ToolCall(...) },
  tool_call_id: 'id',
  thinking: Thinking.new(text: '...', signature: '...'),
  input_tokens: 100,
  output_tokens: 50,
  cached_tokens: 10,
  thinking_tokens: 5,
  model_id: 'gpt-4'
)
```

**Roles** (message.rb:4):
- `:system` — system instruction
- `:user` — user input
- `:assistant` — model response
- `:tool` — tool result (require `tool_call_id`)

### History access

```ruby
chat.messages  # array di Message
chat.messages.each do |msg|
  puts msg.role
  puts msg.content
  puts msg.tool_calls if msg.tool_call?
end

# Reset
chat.reset_messages!
```

### Persistenza esterna

```ruby
messages_data = chat.messages.map(&:to_h)
# Salva messages_data a DB/JSON

# Ripristina:
messages_data.each do |data|
  chat.add_message(data)
end
```

`Message#to_h()` (message.rb:68-78) → serializza tutto:
```ruby
{
  role: :assistant,
  content: 'text',
  model_id: 'gpt-4',
  tool_calls: {...},
  tool_call_id: nil,
  thinking: 'thinking text',
  input_tokens: 100,
  ...
}
```

---

## 9. Schemas / Structured output

### Hash JSON Schema diretto

```ruby
schema = {
  type: 'object',
  properties: {
    name: { type: 'string' },
    age: { type: 'integer' }
  },
  required: ['name'],
  strict: true
}

chat.with_schema(schema).ask("Extract person info from: ...")
```

### `RubyLLM::Schema` DSL (separate gem `ruby_llm-schema`)

```ruby
class PersonSchema < RubyLLM::Schema
  string :name, required: true
  number :age
  array :hobbies, items: { type: 'string' }
end

chat.with_schema(PersonSchema).ask("...")
```

### Inline DSL

```ruby
chat.with_schema(
  RubyLLM::Schema.create do
    string :name, required: true
    number :age
  end
).ask("...")
```

**Normalizzazione** (chat.rb:267-282):
- Accetta `schema` param: classe, istanza, hash, o Schema object
- Chiama `normalize_schema_payload()` → estrae `schema`, `name`, `strict`, `description`
- Payload finale:
  ```json
  {
    "response_format": {
      "type": "json_schema",
      "json_schema": {
        "name": "response",
        "schema": { "type": "object", ... },
        "strict": true
      }
    }
  }
  ```

**Parsing risposta** (chat.rb:204-208):
- Se schema e content è stringa → JSON.parse(content)
- Fallback: keep string

---

## 10. Logging / Debug

### Setup

```ruby
RubyLLM.configure do |config|
  config.log_file = 'llm.log'
  config.log_level = Logger::DEBUG
  config.log_stream_debug = true  # log stream chunks
end

logger = RubyLLM.logger
```

### Env vars

- `RUBYLLM_DEBUG=1` → log_level = DEBUG
- `RUBYLLM_STREAM_DEBUG=true` → StreamAccumulator logs chunks

### Request body logging

Faraday logger (connection.rb:45-51):
```ruby
faraday.response :logger,
                 RubyLLM.logger,
                 bodies: RubyLLM.logger.debug?,  # log request/response body se DEBUG
                 errors: true,
                 headers: false,
                 log_level: :debug
```

### Logger memoization gotcha

`RubyLLM.logger` è memoizzato (ruby_llm.rb:85-89):
```ruby
def logger
  @logger ||= config.logger || Logger.new(...)
end
```

**Problema:** Modifiche a config dopo primo accesso non hanno effetto.
**Soluzione:**
```ruby
RubyLLM.instance_variable_set(:@logger, nil)  # reset
RubyLLM.config.log_level = Logger::DEBUG
RubyLLM.logger  # nuovo logger
```

---

## 11. Errori e retry

### Exception classes (error.rb:5-28)

```ruby
RubyLLM::Error                      # base
  ConfigurationError
  InvalidRoleError
  ModelNotFoundError
  
  BadRequestError (400)
  UnauthorizedError (401)
  RateLimitError (429)
  ContextLengthExceededError (400/429)
  ServerError (500)
  ServiceUnavailableError (502-504, 529)
```

### Retry config (connection.rb:53-65)

```ruby
RubyLLM.configure do |config|
  config.max_retries = 3
  config.retry_interval = 0.1        # sec
  config.retry_backoff_factor = 2    # exponential
  config.retry_interval_randomness = 0.5
end
```

**Retry exceptions** (connection.rb:81-91):
- Timeout, ConnectionFailed
- RateLimitError, ServerError, ServiceUnavailableError, OverloadedError
- NOT BadRequestError (400), UnauthorizedError (401)

### Error parsing

Provider-specific `parse_error(response)` (provider.rb:121-134), fallback generico (error.rb:42-69):
```ruby
case response.status
when 400
  raise BadRequestError if context_length_exceeded?
  raise BadRequestError
when 401
  raise UnauthorizedError
when 429
  raise RateLimitError
when 500
  raise ServerError
when 502..504, 529
  raise ServiceUnavailableError
end
```

---

## 12. Modelli

### Registry

```ruby
models = RubyLLM.models  # Models instance

model = models.find('gpt-4', 'openai')        # con provider
model = models.find('gpt-4')                  # auto-detect provider
models.chat_models                            # filtra type == 'chat'
models.by_provider('openai')                  # filtra provider
models.refresh!                               # scarica da API
```

### Risoluzione modello (Models.resolve, models.rb:106-140)

```ruby
model, provider = Models.resolve('gpt-4', provider: :openai, assume_exists: false)
# ⇒ [Model::Info, Provider instance]
```

**Logic:**
1. Se `assume_exists: true` → crea `Model::Info.default()` on-the-fly (bypassa registry)
2. Se local provider (Ollama) → tenta find in registry, fallback default
3. Altrimenti → `Models.find()` rigoroso (eccezione se non trovato)

### Assume model exists

```ruby
chat = RubyLLM.chat(
  model: 'my-custom-model',
  provider: :ollama,
  assume_model_exists: true
)
```

Bypassa validazione registry. Utile per local/dev models non in JSON registry.

---

## 13. Gotchas / Pitfalls noti

### 1. Logger memoization

Una volta `RubyLLM.logger` acceduto, istanza cached. Cambio config dopo non ha effetto:
```ruby
RubyLLM.logger  # istanziato con config attuale

RubyLLM.configure { |c| c.log_level = Logger::DEBUG }
RubyLLM.logger  # ancora vecchio logger!

# Fix:
RubyLLM.instance_variable_set(:@logger, nil)
```

### 2. Empty tools hash

Se `@tools` è vuoto, campo `tools` NON è incluso in payload (openai/chat.rb:19-21):
```ruby
if tools.any?
  payload[:tools] = tools.map { |_, tool| tool_for(tool) }
end
```

Provider non riceve tools instructions. Aggiungi almeno un tool.

### 3. System role mismatch

Default OpenAI non-stock: `openai_use_system_role: false` → role = `'developer'` (openai/chat.rb:139-144)

Alcuni provider (Ollama, local) potrebbero non riconoscere `'developer'`. Fix:
```ruby
RubyLLM.configure { |c| c.openai_use_system_role = true }
```

### 4. Tool arguments streaming

JSON tool arguments arrivano frammentati in stream. StreamAccumulator concatena stringhe, poi parse() al termine. Non tentare JSON.parse() a metà stream.

### 5. assume_model_exists richiede provider

```ruby
chat = RubyLLM.chat(model: 'phi', assume_model_exists: true)
# ⇒ ArgumentError: "Provider must be specified if assume_model_exists is true"
```

Sempre: `provider: :ollama` (etc.).

### 6. tool_choice normalization

```ruby
chat.with_tool(MyTool, choice: 'my_tool_name')  # string
# ⇒ normalized a symbol :my_tool_name
```

Posso usare symbol, string, classe, o istanza tool.

### 7. Context length exceeded patterns

Errore 400 o 429 con testo matching `CONTEXT_LENGTH_PATTERNS` (error.rb:45-54) → `ContextLengthExceededError` anziché BadRequest/RateLimit. Gestisci specificamente se necessario.

---

## Quick Start: CLI Agent pattern

```ruby
require 'ruby_llm'

RubyLLM.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.default_model = 'gpt-4'
end

chat = RubyLLM.chat
  .with_instructions("You are a helpful assistant for CLI tasks")
  .with_tool(FetchDataTool)
  .with_tool(SaveFileTool)

loop do
  print "> "
  user_input = gets.chomp
  break if user_input == 'quit'

  response = chat.ask(user_input) do |chunk|
    print chunk.content if chunk.content
  end

  puts "\n" if response.tool_call?
end
```

---

**File riferimento principale:**
- lib/ruby_llm.rb — entry point
- lib/ruby_llm/chat.rb — orchestration
- lib/ruby_llm/configuration.rb — config
- lib/ruby_llm/tool.rb — Tool DSL
- lib/ruby_llm/connection.rb — HTTP
- lib/ruby_llm/stream_accumulator.rb — streaming
- lib/ruby_llm/providers/openai/ — OpenAI + OpenAI-compat pattern
- lib/ruby_llm/error.rb — exceptions
