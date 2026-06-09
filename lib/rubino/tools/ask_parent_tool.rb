# frozen_string_literal: true

module Rubino
  module Tools
    # ask_parent — the child->parent escalation channel (the third mechanism of
    # the parent<->subagent comm design). A subagent calls this when it hits a
    # fork it cannot resolve from its sealed prompt ("sqlite or postgres?").
    #
    # Answerer is MIXED: the parent answers from its own context if it can, else
    # it escalates to the HUMAN. This tool implements the wire; the escalation
    # itself reuses Run::ApprovalGate verbatim (the SAME blocking cross-thread
    # hand-off the Option-2 background-approval path already uses):
    #
    #   1. The tool finds the child\'s own BackgroundTasks entry (via the
    #      thread-local Rubino.current_subagent_id set by TaskTool around the
    #      child run). No entry ⇒ this run has no parent (top-level / foreground
    #      sync) and the tool refuses gracefully — never hangs.
    #   2. It registers a Run::ApprovalGate on the entry (BackgroundTasks#begin_ask),
    #      flipping the entry to :blocked_on_human so the parent CLI surfaces the
    #      ⛔ blocked banner + the persistent "N subagent waiting on you" marker,
    #      and informs the parent loop by pushing a note onto the parent\'s
    #      InputQueue (so the parent MODEL sees the question at its next turn and
    #      MAY answer it — the "parent answers if it can" half; the parent\'s
    #      answer routes back through the SAME gate via /reply or a parent path).
    #   3. blocking:true  → the tool BLOCKS on gate.await(timeout: nil) — wait
    #      INDEFINITELY, no auto-default (the owner constraint). The human answers
    #      via /reply <id>, which decides the gate; the answer is the tool result
    #      and enters the child\'s context as the tool message.
    #      blocking:false → the tool returns IMMEDIATELY ("asked, keep working");
    #      the answer is delivered later as a steer note on the child\'s queue
    #      (Loop#inject_steered_input), so the child keeps making progress.
    #
    # SUSPEND/RESUME (the W1/#54 lesson): on the CLI a background subagent runs on
    # its OWN dedicated Thread — NOT a pooled Puma/Solid-Queue worker. Parking
    # that dedicated thread on the gate (blocking:true) therefore holds only the
    # child\'s own thread, never a shared pool, so it cannot freeze the REPL the
    # way a parked Puma worker froze the server (W1). This is exactly how the
    # existing Option-2 approval handler parks the child thread today. A full
    # persist-and-resume suspend (free the thread entirely, rehydrate on answer)
    # is only required for the POOLED web path, which is OUT OF SCOPE here and
    # tracked as a follow-up. A stop (/agents <id> --stop) cancels the gate so a
    # blocking ask unwinds at once instead of waiting forever.
    class AskParentTool < Base
      # Sentinel head used when a non-blocking ask returns to the child: the
      # child keeps working and the real answer arrives later as a steer note.
      NONBLOCKING_ACK = "Question sent to your parent. Keep working with your best "                         "judgement; the answer will be delivered to you as a note "                         "at your next turn if/when it arrives."

      def name
        "ask_parent"
      end

      # Gated by the same `tools.task` delegation key — it is meaningless without
      # the delegation substrate (BackgroundTasks/registry). Disabling delegation
      # disables ask_parent too.
      def config_key
        "task"
      end

      def description
        "Ask YOUR PARENT agent a question when you hit a decision you cannot "         "resolve from the task you were given (e.g. a missing preference, an "         "ambiguous requirement, sqlite-vs-postgres). Your parent answers from "         "its own context if it can, otherwise it asks the human. Use "         "blocking:true when you CANNOT proceed without the answer (you will "         "pause until it arrives); blocking:false (default) when you can keep "         "working and fold the answer in later. Only available to subagents."
      end

      def input_schema
        {
          type: "object",
          properties: {
            question: { type: "string", description: "The question for your parent. Be specific and self-contained." },
            blocking: {
              type: "boolean",
              description: "true = pause until answered (you cannot proceed without it). "                            "false (default) = keep working; the answer is delivered later as a note."
            }
          },
          required: %w[question]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        question = (arguments["question"] || arguments[:question]).to_s.strip
        blocking = blocking_arg(arguments)
        return "Error: question is required" if question.empty?

        id = Rubino.current_subagent_id
        entry = id && BackgroundTasks.instance.find(id)
        unless entry
          return "Error: ask_parent is only available to a background subagent "                  "(no parent to ask). Resolve this from your task instead."
        end

        escalate(entry, question, blocking)
      rescue Rubino::Interrupted
        # A /agents <id> --stop (or teardown) cancelled the gate while we were
        # parked. Unwind cleanly: report it as denied/cancelled so the child can
        # finish rather than hang.
        BackgroundTasks.instance.end_ask(entry&.id) if defined?(entry) && entry
        "Your parent question was cancelled (the run is being stopped)."
      end

      private

      # blocking defaults to FALSE (the cheap, non-freezing default): the child
      # keeps working and the answer is injected later. Only an explicit true
      # opts into the indefinite blocking wait.
      def blocking_arg(arguments)
        raw = arguments.key?("blocking") ? arguments["blocking"] : arguments[:blocking]
        [true, "true", 1, "1"].include?(raw)
      end

      def escalate(entry, question, blocking)
        gate   = Run::ApprovalGate.new
        ask_id = "ask_#{entry.id}"
        gate.register(ask_id)
        # Route by OWNER (S4): a child with an agent-parent blocks on that PARENT
        # (:blocked_on_parent, answered by the parent model's `answer_child`); a
        # human/top-level-owned child blocks on the HUMAN (:blocked_on_human,
        # answered via /reply). begin_ask records the right status from the owner.
        owner_id = entry.owner_subagent_id
        BackgroundTasks.instance.begin_ask(
          entry.id, gate: gate, ask_id: ask_id, question: question,
          blocking: blocking, owner_id: owner_id
        )
        if owner_id
          notify_agent_parent(owner_id, entry, question)
        else
          surface_and_notify(entry, question)
        end

        if blocking
          await_human(entry, gate, ask_id)
        else
          # Non-blocking: the child keeps working. The answer arrives later as a
          # steer note via the gate-watcher the CLI installs at /reply time
          # (BackgroundTasks#steer pushes onto the child\'s queue). We do NOT
          # clear the ask state here — the entry stays :blocked_on_human on the
          # card until the human answers, so a non-blocking ask is still visible
          # and answerable; the child simply does not pause for it.
          NONBLOCKING_ACK
        end
      end

      # Parks the child\'s OWN thread on the gate, indefinitely (timeout: nil —
      # the owner constraint: wait forever, no auto-default). Returns the answer
      # (from /reply or answer_child, both via gate.decide) as the tool result so
      # it enters the child\'s context. A cancel raises Interrupted (handled in
      # #call).
      def await_human(entry, gate, ask_id)
        decision = gate.await(ask_id, timeout: nil)
        answer   = decision.equal?(Run::ApprovalGate::EXPIRED) ? nil : decision.to_s
        BackgroundTasks.instance.end_ask(entry.id)
        if answer.nil? || answer.empty?
          "Your parent did not provide an answer. Proceed with your best judgement."
        else
          "Your parent answered: #{answer}"
        end
      end

      # Notifies the AGENT-parent (owner) of a child question by pushing the
      # [subagent-question] note onto the OWNER\'s steer_queue — the same
      # turn-boundary channel a steer rides — so the parent MODEL sees it at its
      # next iteration and can answer with `answer_child` (or escalate up via its
      # own ask_parent). No human surfacing here: a :blocked_on_parent ask is the
      # agent-parent\'s job, not the human\'s. Best-effort.
      def notify_agent_parent(owner_id, entry, question)
        BackgroundTasks.instance.steer(owner_id, agent_parent_notice(entry, question))
      rescue StandardError
        nil
      end

      def agent_parent_notice(entry, question)
        "[subagent-question] Your subagent #{entry.id} ('#{entry.subagent}') is asking you:\n" \
        "#{question}\n" \
        "Answer it with answer_child(task_id: \"#{entry.id}\", answer: \"…\") if you can. " \
        "If you cannot answer from your own context, escalate by calling ask_parent yourself."
      end

      # Surfaces the blocked state on the parent CLI (a committed banner in
      # scrollback + a card repaint so the persistent ⛔ marker shows) and pushes
      # a note onto the parent\'s InputQueue so the parent MODEL learns of the
      # question at its next turn and may answer it. DISPLAY/notify only — the
      # authoritative answer delivery is the gate decision (/reply) or, for the
      # parent-model answer, a future gate-decide path.
      def surface_and_notify(entry, question)
        Rubino.background_sink&.push(parent_notice(entry, question))
        parent_ui = Rubino.instance_variable_get(:@ui)
        return unless parent_ui.is_a?(UI::CLI)

        parent_ui.subagent_ask_banner(entry.id, entry.subagent, question) if parent_ui.respond_to?(:subagent_ask_banner)
        parent_ui.set_subagent_cards if parent_ui.respond_to?(:set_subagent_cards)
      rescue StandardError
        nil
      end

      def parent_notice(entry, question)
        "[subagent-question] Task #{entry.id} (subagent \'#{entry.subagent}\') is asking you:\n"         "#{question}\n"         "If you can answer from your own context, reply to it with "         "/reply #{entry.id} <answer> (or tell the user). If not, the human will be asked."
      end
    end
  end
end
