# frozen_string_literal: true

module Rubino
  module Tools
    # answer_child — the MODEL-callable answer to a child's ask_parent (S4). The
    # agent-parent counterpart of the human `/reply <id> <answer>`: when a
    # subagent calls ask_parent and it is OWNED by an agent (not the human), the
    # question lands on this parent's steer_queue as a [subagent-question] note;
    # the parent model reads it at its next turn and answers it with this tool.
    #
    # SCOPED AT CALL (like steer/probe, the S1 correction): registered for ALL
    # agents and AUTHORIZED by OWNERSHIP at call time. The caller is the
    # thread-local Rubino.current_subagent_id (nil ⇒ the human / top-level agent).
    # The target must be the caller's OWN DIRECT child (BackgroundTasks.owned_by?)
    # AND it must actually be waiting on an ask (it has an ask_gate). NOT on any
    # strip list.
    #
    # Mechanism reuse: it wraps BackgroundTasks#deliver_answer verbatim — the SAME
    # ONE answer wire the human /reply path uses (decide the gate + push the
    # [parent answer] steer note + clear the blocked state). No new transport.
    #
    # An agent-parent that CANNOT answer from its own context does NOT use this
    # tool: it escalates by calling its OWN ask_parent (recursion up the tree).
    class AnswerChildTool < Base
      def name
        "answer_child"
      end

      # Gated by the same `tools.task` delegation key — answering a child is
      # meaningless without the delegation substrate. Disabling delegation
      # disables answer_child too.
      def config_key
        "task"
      end

      def description
        "Answer one of YOUR OWN subagents that asked you a question via " \
        "ask_parent (you will have received it as a [subagent-question] note). " \
        "The answer is delivered into that child's context: it unblocks a child " \
        "that paused for it and folds into a child that kept working. You can " \
        "ONLY answer a subagent you started (your direct child) that is actually " \
        "waiting on you. If you CANNOT answer from your own context, do NOT guess " \
        "— escalate by calling ask_parent yourself."
      end

      def input_schema
        {
          type: "object",
          properties: {
            task_id: { type: "string", description: "The id (sa_…) of YOUR subagent that asked you." },
            answer:  { type: "string", description: "Your answer. Be specific and self-contained — it enters the child's context." }
          },
          required: %w[task_id answer]
        }
      end

      # Answering a child is a low-risk, non-destructive hand-off (the child
      # carries its own approval/risk gates for whatever it does with the answer).
      def risk_level
        :low
      end

      def call(arguments)
        task_id = (arguments["task_id"] || arguments[:task_id]).to_s.strip
        answer  = (arguments["answer"]  || arguments[:answer]).to_s.strip
        return "Error: answer is required" if answer.empty?

        caller_id = Rubino.current_subagent_id
        registry  = BackgroundTasks.instance

        # Ownership: only a DIRECT child of the caller may be answered.
        unless registry.owned_by?(caller_id, task_id)
          return "Error: #{task_id} is not one of your subagents."
        end

        # It must actually be waiting on an ask (deliver_answer no-ops without a
        # live ask_gate). Covers a missing/finished/not-blocked child uniformly.
        unless registry.deliver_answer(task_id, answer)
          return "#{task_id} is not waiting on you."
        end

        "↳ answered #{task_id}: #{truncate(answer, 80)}\n✓ #{task_id} resumes at its next turn"
      end

      private

      def truncate(text, max)
        s = text.to_s
        s.length > max ? "#{s[0, max]}…" : s
      end
    end
  end
end
