# frozen_string_literal: true

require_relative "subagent_probe"

module Rubino
  module Tools
    # probe — the MODEL-callable EPHEMERAL peek into one of the caller's OWN
    # running children (S3). The model counterpart of the human
    # `/agents <id> probe "..."`. Two paths, both read-only (they append NOTHING
    # to the child's session — the EPHEMERAL invariant):
    #
    #   live:false (DEFAULT, FREE): build the answer from the registry's
    #     live-progress fields ONLY (status / tool_count / last_activity + the
    #     bounded activity_log ring the /agents drill-in already tails). NO model
    #     call — unlimited.
    #   live:true (BILLED): run ONE side-inference over a read-only snapshot of
    #     the child's transcript (SubagentProbe#peek) and return the answer. This
    #     costs a model round-trip, so it is BUDGETED per child
    #     (tasks.max_live_probes_per_child, default 5). Over budget → the model is
    #     told to use the free snapshot.
    #
    # SCOPED AT CALL (the S1 correction): probe is registered for ALL agents and
    # authorized by OWNERSHIP at call time — the target must be the caller's OWN
    # direct child (BackgroundTasks.owned_by?). Registered normally, NOT on any
    # strip list. Does NOT touch the human CLI probe path (executor.rb).
    class ProbeTool < Base
      # How many activity_log lines the cheap snapshot renders (matches the
      # /agents drill-in's `recent:` ring).
      RECENT_MAX = 6

      def initialize(probe: nil)
        # Test seam: inject a SubagentProbe (or any object responding to #peek)
        # so the live path can be driven without a real model.
        @probe = probe
      end

      def name
        "probe"
      end

      # Gated by the same `tools.task` delegation key — probing a child is
      # meaningless without the delegation substrate.
      def config_key
        "task"
      end

      def description
        "Check on one of YOUR OWN running subagents WITHOUT disturbing it (this " \
          "is read-only — it changes nothing about what the child does). By default " \
          "(live:false) it returns a FREE instant snapshot: the child's status, how " \
          "many tools it has run, its last activity, and a few recent lines — no " \
          "model call. Set live:true to ask the child a specific question answered " \
          "from its current context by a one-shot model peek (this costs a billed " \
          "round-trip and is budgeted per child; prefer the free snapshot). You can " \
          "ONLY probe subagents you started (your direct children)."
      end

      def input_schema
        {
          type: "object",
          properties: {
            task_id: { type: "string", description: "The id (sa_…) of YOUR subagent to probe." },
            question: { type: "string",
                        description: "What you want to know. For a free snapshot this frames the check; for live:true it is the question the child answers from its context." },
            live: {
              type: "boolean",
              description: "false (default) = FREE instant snapshot from the registry, no model call. " \
                           "true = billed one-shot model peek over the child's transcript (budgeted per child)."
            }
          },
          required: %w[task_id question]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        task_id  = (arguments["task_id"]  || arguments[:task_id]).to_s.strip
        question = (arguments["question"] || arguments[:question]).to_s.strip
        live     = live_arg(arguments)

        caller_id = Rubino.current_subagent_id
        registry  = BackgroundTasks.instance
        entry     = task_id.empty? ? nil : registry.find(task_id)

        return "Cannot probe #{task_id} — no such subagent." unless entry
        return "Error: question is required" if question.empty?
        unless registry.owned_by?(caller_id, task_id)
          return "Error: #{task_id} is not one of your subagents — you can only probe children you started."
        end

        live ? probe_live(registry, entry, question) : probe_cheap(entry)
      end

      private

      # live defaults to FALSE (the free, unbilled snapshot). Only an explicit
      # true opts into the billed model peek.
      def live_arg(arguments)
        raw = arguments.key?("live") ? arguments["live"] : arguments[:live]
        [true, "true", 1, "1"].include?(raw)
      end

      # FREE path: render the live-progress fields only. NO model call.
      def probe_cheap(entry)
        recent = Array(entry.activity_log).last(RECENT_MAX)
        lines  = recent.empty? ? "(none yet)" : recent.join("\n")
        "probe #{entry.id} · #{entry.subagent} · #{entry.status} · " \
          "#{entry.tool_count.to_i} tools · last: #{entry.last_activity || "—"}\n" \
          "recent:\n#{lines}"
      end

      # BILLED path: enforce the per-child budget, then run the one-shot peek.
      # peek is best-effort (never raises) — a failure is reported inline.
      def probe_live(registry, entry, question)
        max = max_live_probes
        if entry.probe_count.to_i >= max
          return "Error: live-probe budget exhausted for #{entry.id} (max #{max} per child). " \
                 "Use live:false for a free snapshot."
        end

        registry.record_live_probe(entry.id)
        answer = probe_engine.peek(entry: entry, question: question)
        "probe #{entry.id} (live) ⟵ #{answer}"
      end

      def probe_engine
        @probe ||= SubagentProbe.new
      end

      def max_live_probes
        cfg = Rubino.configuration if Rubino.respond_to?(:configuration)
        Integer(cfg&.tasks_max_live_probes_per_child)
      rescue StandardError, TypeError, ArgumentError
        5
      end
    end
  end
end
