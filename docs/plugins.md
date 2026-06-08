# Plugin System

rubino defines 38 hook points for extending and customizing behavior.

> **Status:** The plugin registry and DSL (`Rubino.plugin do ... end`) are
> functional, but the hook points themselves are **not yet fired from the
> lifecycle** — they are declared in `Plugins::HOOKS` but not all are wired into
> the runtime yet. This document describes the intended hooks and their context
> shape (design intent); subscribing to a hook that isn't fired yet is harmless
> but has no effect.

## Creating a Plugin

Place Ruby files in `.rubino/plugins/` or `~/.rubino/plugins/`:

```ruby
# .rubino/plugins/logging.rb
Rubino.plugin do
  on(:tool_execute_before) do |context|
    puts "[AUDIT] Tool: #{context[:tool_name]} args: #{context[:arguments]}"
    context  # Return context (optionally modified)
  end

  on(:tool_execute_after) do |context|
    puts "[AUDIT] Result: #{context[:result]&.truncated_preview}"
    context
  end
end
```

## Hook Behavior

- Hooks receive a context hash and should return it (optionally modified)
- Multiple handlers per hook are supported (executed in registration order)
- If a handler returns a Hash, it's merged into the context for the next handler
- Errors in hooks are caught and logged but don't break the main flow

## All 38 Hooks

### Tool Lifecycle

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `tool_execute_before` | Before any tool runs | `tool_name`, `arguments`, `session_id` |
| `tool_execute_after` | After tool completes | `tool_name`, `arguments`, `result`, `duration` |
| `tool_approval_before` | Before approval check | `tool_name`, `risk_level`, `arguments` |
| `tool_approval_after` | After approval decision | `tool_name`, `decision` (:allow/:ask/:deny) |
| `tool_result_transform` | Transform tool output | `tool_name`, `result` |

### Shell

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `shell_env` | Inject env vars into shell | `command`, `env` (mutable hash) |
| `shell_execute_before` | Before shell command | `command`, `cwd` |
| `shell_execute_after` | After shell command | `command`, `output`, `exit_code` |

### File Operations

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `file_read_before` | Before reading a file | `path` |
| `file_read_after` | After reading a file | `path`, `content`, `size` |
| `file_write_before` | Before writing a file | `path`, `content` |
| `file_write_after` | After writing a file | `path`, `size` |

### Context Compaction

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `compaction_before` | Before compaction starts | `session_id`, `message_count`, `token_estimate` |
| `compaction_after` | After compaction finishes | `session_id`, `saved_tokens`, `new_session_id` |
| `compaction_context_inject` | Inject custom context into compaction summary | `session_id`, `messages` |

### Sessions

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `session_start` | New session created | `session_id`, `model`, `source` |
| `session_end` | Session ended | `session_id`, `message_count` |
| `session_fork` | Session forked | `source_id`, `forked_id`, `at_message` |
| `session_persist` | Session state saved | `session_id`, `token_count` |

### Messages

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `message_before` | Before message is processed | `role`, `content`, `session_id` |
| `message_after` | After message persisted | `message_id`, `role`, `content` |
| `message_stream_chunk` | Each streaming chunk | `chunk`, `session_id` |

### Memory

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `memory_extract` | During memory extraction | `session_id`, `candidates` |
| `memory_save_before` | Before saving a memory | `kind`, `content` |
| `memory_retrieve_after` | After retrieving memories | `memories`, `context` |

### Jobs

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `job_before` | Before job execution | `job_type`, `payload` |
| `job_after` | After job completes | `job_type`, `result` |
| `job_failed` | When job fails | `job_type`, `error`, `attempts` |

### Model/LLM

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `model_call_before` | Before LLM API call | `model`, `messages`, `tools` |
| `model_call_after` | After LLM response | `model`, `response`, `tokens` |
| `model_response_transform` | Transform LLM response | `content`, `tool_calls` |

### Prompt Assembly

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `prompt_assemble_before` | Before building prompt | `session_id`, `memory_context` |
| `prompt_assemble_after` | After prompt built | `messages`, `token_estimate` |

### Agent

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `agent_switch` | Agent switched | `from`, `to` |
| `agent_route` | Input routed to agent | `input`, `agent_name` |

### System

| Hook | Trigger | Context Keys |
|------|---------|--------------|
| `config_reload` | Config reloaded | `config` |
| `startup` | Application starting | `version` |
| `shutdown` | Application stopping | `reason` |

## Examples

### Auto-format after writes

```ruby
Rubino.plugin do
  on(:file_write_after) do |context|
    path = context[:path]
    if path.end_with?(".rb")
      system("rubocop -A '#{path}' 2>/dev/null")
    elsif path.end_with?(".js", ".ts")
      system("prettier --write '#{path}' 2>/dev/null")
    end
    context
  end
end
```

### Inject environment into shell

```ruby
Rubino.plugin do
  on(:shell_env) do |context|
    context[:env]["RAILS_ENV"] ||= "development"
    context[:env]["BUNDLE_GEMFILE"] ||= File.join(Dir.pwd, "Gemfile")
    context
  end
end
```

### Block dangerous operations

```ruby
Rubino.plugin do
  on(:tool_execute_before) do |context|
    if context[:tool_name] == "shell"
      cmd = context.dig(:arguments, "command") || ""
      if cmd.match?(/rm\s+-rf\s+\/|dd\s+if=|mkfs|format/)
        raise Rubino::ToolError, "Blocked dangerous command: #{cmd}"
      end
    end
    context
  end
end
```

### Custom telemetry

```ruby
Rubino.plugin do
  on(:model_call_after) do |context|
    tokens = context[:tokens] || 0
    model = context[:model]
    File.open("usage.log", "a") { |f| f.puts "#{Time.now.iso8601} #{model} #{tokens}" }
    context
  end
end
```
