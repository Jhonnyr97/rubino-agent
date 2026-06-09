# frozen_string_literal: true

module Rubino
  module UI
    # Abstract base class for all UI adapters.
    # Defines the interface that CLI, API, and Null must implement.
    # No output method should be called directly from core logic;
    # all output flows through one of these methods.
    class Base
      def info(message)
        raise NotImplementedError, "#{self.class}#info not implemented"
      end

      def success(message)
        raise NotImplementedError, "#{self.class}#success not implemented"
      end

      def warning(message)
        raise NotImplementedError, "#{self.class}#warning not implemented"
      end

      def error(message)
        raise NotImplementedError, "#{self.class}#error not implemented"
      end

      def status(message)
        raise NotImplementedError, "#{self.class}#status not implemented"
      end

      # Opens a box: `┌─ HH:MM · type · pieces ─────` filling the box width.
      # Every visible scrollback block (user, thinking, tool, assistant, replay)
      # is rendered as a box; body lines below get a `│ ` prefix and the box
      # is closed with `box_close`. Pieces are joined with `·`. `at:` overrides
      # the timestamp so replay preserves the original time of each historical
      # step instead of showing "now" for the whole resumed session. `color:`
      # overrides the auto-color (used by tool_finished to flip done to red).
      def box_open(*pieces, at: nil, color: nil)
        raise NotImplementedError, "#{self.class}#box_open not implemented"
      end

      # Closes the currently-open box with `└─ pieces ─────`. When no pieces
      # are given, emits a bare `└────` line — used for boxes that have no
      # trailing metric (user, assistant, thinking). For tool boxes the
      # caller passes `"done", name, metrics` so the bottom border carries
      # the cost/scope of the call.
      def box_close(*pieces, color: nil)
        raise NotImplementedError, "#{self.class}#box_close not implemented"
      end

      # Emits the payload that goes under a header (replay assistant body,
      # one-shot text dumps, anything that isn't a stream chunk). Routing it
      # through the UI rather than $stdout means the Null adapter still
      # records it for tests and the CLI can later style/wrap it.
      def body(text)
        raise NotImplementedError, "#{self.class}#body not implemented"
      end

      # A finished assistant message. The CLI renders it as markdown; other
      # adapters fall back to plain body text. Part of the UI contract so the
      # session-history replay (resume/continue) works on every adapter.
      def assistant_text(text)
        body(text)
      end

      # Small metadata line, dim, no header. Used for the `↳ turn · Xs · N
      # tools · Y tok` summary after the final assistant message, and any
      # similar low-priority annotation that should sit close to the block
      # it describes without competing visually.
      def note(text)
        raise NotImplementedError, "#{self.class}#note not implemented"
      end

      def stream(chunk)
        raise NotImplementedError, "#{self.class}#stream not implemented"
      end

      def stream_end
        raise NotImplementedError, "#{self.class}#stream_end not implemented"
      end

      # Replays a user message from session history (resume / continue).
      # Lets the CLI render past turns with a stable "you >" label so the
      # scrolled-back transcript matches what the user typed at the time.
      def replay_user_input(text)
        raise NotImplementedError, "#{self.class}#replay_user_input not implemented"
      end

      # Called when the model call starts but no chunk has arrived yet.
      # Lets the UI show a transient "thinking…" affordance so the user
      # sees something is happening during TTFB and when show_reasoning
      # is disabled (otherwise the terminal sits silent until the first
      # content chunk lands).
      def thinking_started
        raise NotImplementedError, "#{self.class}#thinking_started not implemented"
      end

      def table(headers:, rows:)
        raise NotImplementedError, "#{self.class}#table not implemented"
      end

      def ask(prompt)
        raise NotImplementedError, "#{self.class}#ask not implemented"
      end

      # Arrow-key single-select menu. +choices+ is an array of
      # [label, value] pairs; returns the chosen value, or nil when no
      # interactive selection is possible (non-TTY / Null adapter) so callers
      # fall back to a non-interactive path.
      def select(prompt, choices)
        raise NotImplementedError, "#{self.class}#select not implemented"
      end

      # `scope:` is part of the contract for ALL adapters (not just API):
      # ToolExecutor#request_approval always passes it. CLI/Null ignore it;
      # API uses it as the session-approval cache key. Keeping the keyword in
      # the shared signature is what stops UI::CLI from raising
      # `ArgumentError: unknown keyword: :scope` on every interactive tool
      # approval. `**context` absorbs the enriched approval fields (tool/
      # command/pattern_key/description) that ToolExecutor passes for the /v1
      # event — only UI::API consumes them; CLI/Null/SubagentView ignore them.
      def confirm(question, scope: nil, **context)
        raise NotImplementedError, "#{self.class}#confirm not implemented"
      end

      # `at:` overrides the timestamp on the tool box top — replay uses it so
      # historical tool calls show when they actually happened, not "now".
      # Live calls leave `at:` nil and get current time.
      def tool_started(name, arguments: nil, at: nil)
        raise NotImplementedError, "#{self.class}#tool_started not implemented"
      end

      def tool_finished(name, result: nil)
        raise NotImplementedError, "#{self.class}#tool_finished not implemented"
      end

      # Body block printed inside the open tool box, between the top and
      # `done` rules. `kind:` controls coloring:
      #   :plain — every line dim (default; for shell/grep/glob/read
      #            previews where a leading `-` is `ls -la` permissions,
      #            not a diff removal)
      #   :diff  — `+ ` lines green, `- ` lines red, rest dim (for edit)
      # Caller is responsible for trimming the text first (Util::Output.preview).
      def tool_body(text, kind: :plain)
        raise NotImplementedError, "#{self.class}#tool_body not implemented"
      end

      # `at:` overrides the timestamp shown on the compaction free line.
      # Live events leave it nil and pick up current time; replay (if
      # compaction events ever become stored in history) can pin the
      # original moment.
      def compression_started(at: nil)
        raise NotImplementedError, "#{self.class}#compression_started not implemented"
      end

      def compression_finished(metadata, at: nil)
        raise NotImplementedError, "#{self.class}#compression_finished not implemented"
      end

      def job_enqueued(type)
        raise NotImplementedError, "#{self.class}#job_enqueued not implemented"
      end

      def job_started(type)
        raise NotImplementedError, "#{self.class}#job_started not implemented"
      end

      def job_finished(type)
        raise NotImplementedError, "#{self.class}#job_finished not implemented"
      end

      def separator
        raise NotImplementedError, "#{self.class}#separator not implemented"
      end

      def blank_line
        raise NotImplementedError, "#{self.class}#blank_line not implemented"
      end

      # Signals a Modes transition (e.g. user typed `/mode plan` or an API
      # caller invoked Modes.set). CLI renders a `┄ HH:MM · mode → plan ┄`
      # free line; API emits a `mode_changed` event the orchestrator can
      # forward to the web client; Null records it for tests.
      # `previous:` is the mode active *before* the transition, used to
      # render the arrow ("default → plan").
      def mode_changed(name, previous: nil)
        raise NotImplementedError, "#{self.class}#mode_changed not implemented"
      end

      # Echoes a message the user typed *during* a running turn — the steering
      # / "talk while it works" affordance. The background reader captured the
      # line and parked it for the next turn; this just confirms it visually so
      # the keystrokes don't disappear into the streaming output. Concrete (not
      # abstract) and a no-op by default: only the CLI shows the dim
      # `queued ▸ …` echo; API/Null have nothing meaningful to render and
      # inherit the no-op rather than each restating it.
      def queued(text); end

      # Echoes a message that was picked up MID-TURN at an agent-loop iteration
      # boundary and injected as a user message into the current turn (the
      # Phase-2 steering / "Enter injects into the current turn" affordance).
      # Distinct from #queued, which parks text for the NEXT turn: this text is
      # already part of the live turn, so the CLI renders a dim
      # `↳ ricevuto mentre lavoravo: …` confirmation. Concrete no-op by default;
      # only the CLI has something to render. API surfaces it via the
      # INPUT_INJECTED bus event, not this echo.
      def input_injected(text); end

      # Commits the standardized `⎿ interrupted` marker right after the partial
      # answer that's kept when a turn is cancelled (Ctrl+C, or the interrupt-by-
      # default Enter on a type-ahead line). Concrete no-op by default; only the
      # CLI renders the dim marker. API surfaces the cancel via its own events;
      # Null records nothing.
      def turn_interrupted; end

      # True when this adapter parks the run on a cross-thread gate for human
      # approvals/clarifications (the HTTP/API path) rather than prompting
      # inline on a terminal. The agent loop uses this to run an interactive
      # turn NON-STREAMING so no upstream LLM socket is held open during the
      # wait. Default false: CLI/Null prompt inline (or auto-answer) and never
      # park, so they keep streaming.
      def blocking_human_input?
        false
      end
    end
  end
end
