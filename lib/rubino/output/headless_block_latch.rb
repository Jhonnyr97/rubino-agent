# frozen_string_literal: true

module Rubino
  module Output
    # Process-global fail-closed latch for headless (`rubino prompt`/-q) runs
    # (F1-subagents).
    #
    # The one-shot CLI reads the PARENT's UI::Null#approval_blocked? after the run
    # to decide the exit code (#260). But a `task` subagent runs on a SEPARATE,
    # fresh UI::Null (nested_ui ⇒ Null off the CLI), so when the CHILD's dangerous
    # tool is fail-closed-blocked the latch lands on that DISCARDED child adapter
    # — the parent's UI::Null never sees it, and the CLI reported exit 0 + empty
    # stderr even though the block held and the tool never ran. A direct
    # `rubino prompt` of the same dangerous action correctly exits 2; routing it
    # through a subagent silently looked like success, hiding the refusal from CI.
    #
    # Fix: every UI::Null records a fail-closed block HERE too while a headless run
    # is active, regardless of which (parent or child) adapter caught it. The
    # one-shot exit check consults this latch in addition to the parent adapter,
    # so a subagent-blocked headless run exits non-zero with the block notice on
    # stderr — the same outcome as the direct run. Reset around each one-shot run
    # so a long-lived embedder/test process doesn't carry a stale block across
    # invocations.
    module HeadlessBlockLatch
      module_function

      @mutex = Mutex.new
      @messages = []

      # Record a fail-closed block message. Called from UI::Null#tool_blocked
      # while Rubino.headless? — from the parent OR any (foreground) subagent.
      def record(message)
        @mutex.synchronize { @messages << message.to_s }
      end

      # True when any tool was fail-closed-blocked anywhere in this headless run.
      def blocked?
        @mutex.synchronize { !@messages.empty? }
      end

      # The recorded block notices, in order, for the CLI to echo to stderr.
      def messages
        @mutex.synchronize { @messages.dup }
      end

      # Clear the latch. Called at the start of each one-shot run so a reused
      # process never inherits a stale block.
      def reset!
        @mutex.synchronize { @messages = [] }
      end
    end
  end
end
