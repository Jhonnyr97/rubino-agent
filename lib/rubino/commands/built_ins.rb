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
        "/probe"        => "Ask an ephemeral side-question (not saved); tip: start a line with '? '",
        "/branch"       => "Fork the current session into a new one and switch into it",
        "/memory"       => "Inspect/search/forget what the agent remembers",
        "/agents"       => "List background subagents; steer/probe a running one, or view output",
        "/tasks"        => "Alias for /agents",
        "/reply"        => "Answer a subagent that is blocked waiting on you (ask_parent)",
        "/skills"       => "List available skills",
        "/add-dir"      => "Add an extra allowed workspace directory (write/edit can reach it)",
        "/dirs"         => "List the current workspace roots",
        "/mode"         => "Show or switch mode (default | plan | yolo)",
        "/reasoning"    => "Show or switch how reasoning is shown (hidden | collapsed | full)",
        "/think"        => "Show or switch thinking effort (off | low | medium | high)",
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
