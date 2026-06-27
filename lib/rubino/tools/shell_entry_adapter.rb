# frozen_string_literal: true

module Rubino
  module Tools
    # Read-time adapter that makes a ShellRegistry::Entry look like a
    # BackgroundTasks::Entry to the SHARED UI seams (cards, picker, /stop, attach)
    # WITHOUT copying its state into a second registry. This is the DRY core of
    # "a background shell gets the same dev UX as a subagent": BackgroundTasks#running
    # merges these adapters in, so the cards/picker render them with ZERO branches,
    # and #stop / #feed_input route control to the live ShellRegistry process.
    #
    # Why an adapter and not a real BackgroundTasks entry: a duplicated entry would
    # need status sync (two sources of truth), would double the completion notice
    # ShellRegistry already pushes, and would consume the subagent concurrency cap
    # + allocate a dead steer_queue. Reading the live ShellRegistry entry at render
    # time dissolves all three.
    #
    # The renderers read only plain accessors (id/subagent/status/prompt/...);
    # method_missing returns nil for any field a shell has no analogue for
    # (approval_*, budget_request, runner, steer_queue, …) so a renderer touching
    # one never raises.
    class ShellEntryAdapter
      def initialize(shell_entry, registry: ShellRegistry.instance)
        @shell = shell_entry
        @registry = registry
      end

      attr_reader :shell

      def id          = @shell.id
      def subagent    = "shell"
      # the card's title line
      def prompt      = @shell.command
      def started_at  = @shell.started_at
      # :running / :completed / :failed (derived)
      def status      = @registry.status(@shell)
      # a shell runs no tools — nil omits the card's "N tools" segment entirely
      def tool_count = nil
      def activity_log = []
      # Mirrors BackgroundTasks::Entry#budget_request — a FIELD the renderers read,
      # not a predicate, so it keeps the field name (no `?`).
      def budget_request = false # rubocop:disable Naming/PredicateMethod
      def depth       = 0
      def shell?      = true

      # The attach view replays a subagent's transcript via #messages; a shell has
      # none — it falls through to the live output-tail render instead.
      def messages = []

      # True while the process is still alive — the single liveness rule every UI
      # surface filters by (mirrors BackgroundTasks.live_status?).
      def live? = @shell.wait_thr&.alive? || false

      # Stop from the UI (/stop / picker): SIGTERM→grace→SIGKILL the process group,
      # then retire so the captured output stays retrievable. Reuses the one
      # ShellRegistry kill seam (also used by shell_kill).
      def stop = @registry.terminate(@shell)

      # Attach/focus input: the user's keystrokes/line go straight to the PTY (or
      # pipe) stdin — the shell analogue of steering a subagent.
      def feed_input(text, enter: true) = @registry.write_input(@shell, text, enter: enter)

      # Polymorphic counterpart to a subagent's #steer: a shell has no turn to
      # fold a note into — "steering" it means writing the text to its stdin.
      def steer(text) # rubocop:disable Naming/PredicateMethod -- an action mirroring Entry#steer, not a predicate
        feed_input(text)
        true
      end

      # Polymorphic counterpart to a subagent's #peek: a shell has no model
      # context to side-infer over, so a "probe" is an instant snapshot of its
      # recent output — NO LLM round-trip (the question is informational).
      def peek(_question = nil)
        out = output_all.to_s
        return "(no output captured yet)" if out.strip.empty?

        out.lines.last(20).join.rstrip
      end

      # The live output a shell's attach view tails (no session/transcript).
      def output_new = @registry.read_new(@shell)
      def output_all = @registry.read_all(@shell)

      # Any field a shell has no analogue for (approval_gate, runner, steer_queue,
      # approval_question, last_activity, finished_at, …) reads as nil so the
      # shared renderers never raise on a shell row.
      def respond_to_missing?(_name, _include_private = false) = true
      def method_missing(_name, *_args) = nil
    end
  end
end
