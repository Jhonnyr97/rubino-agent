# frozen_string_literal: true

module Rubino
  module Commands
    # Single source of truth for built-in slash command names + descriptions.
    # Referenced by the CLI UI for tab-completion and by the Executor for
    # `/help` and the unknown-command "Available" list (so both stay in sync —
    # previously `/help` omitted /quit and /mode, L7).
    module BuiltIns
      # Ordered: name => one-line description shown by `/help`.
      DESCRIPTIONS = {
        "/status"       => "Overview: model, mode, session, memory, background work",
        "/sessions"     => "List recent sessions and resume one",
        "/new"          => "Start a fresh session (the current one is left intact)",
        "/memory"       => "Inspect/search/forget what the agent remembers",
        "/agents"       => "List background subagents; steer/probe a running one, or view output",
        "/tasks"        => "Alias for /agents",
        "/reply"        => "Answer a subagent that is blocked waiting on you (ask_parent)",
        "/skills"       => "List available skills",
        "/mode"         => "Show or switch mode (default | plan | yolo)",
        "/commands"     => "List custom commands (and how to make them)",
        "/help"         => "Show this help",
        "/paste"        => "Attach an image from the clipboard",
        "/clear-images" => "Drop pending image attachments",
        "/exit"         => "End session",
        "/quit"         => "End session"
      }.freeze

      NAMES = DESCRIPTIONS.keys.freeze
    end
  end
end
