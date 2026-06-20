# frozen_string_literal: true

require "yaml"

module Eval
  # A single eval task spec, loaded from tasks.yml.
  #
  #   id      — unique identifier
  #   kind    — :edit (strong, file-based check) or :find (weak, answer-keyword)
  #   fixture — fixture dir name under eval/fixtures/, or nil for none
  #   prompt  — the instruction sent to rubino
  #   check   — shell command run in the workspace; exit 0 = PASS
  Task = Struct.new(:id, :kind, :fixture, :prompt, :check, keyword_init: true) do
    def find? = kind == :find
    def edit? = kind == :edit
  end

  # Loads Task specs from a tasks.yml file.
  module TaskLoader
    module_function

    # Loads all tasks from a YAML file. Optionally filters by an allowlist of ids.
    def load(path, only: nil)
      raw = YAML.safe_load_file(path)
      tasks = Array(raw).map do |h|
        Task.new(
          id: h.fetch("id"),
          kind: h.fetch("kind").to_sym,
          fixture: h["fixture"],
          prompt: h.fetch("prompt").strip,
          check: h.fetch("check")
        )
      end
      only ? tasks.select { |t| only.include?(t.id) } : tasks
    end
  end
end
