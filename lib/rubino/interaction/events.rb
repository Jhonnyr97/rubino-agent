# frozen_string_literal: true

module Rubino
  module Interaction
    # Defines all event types used in the system.
    # Acts as documentation and provides constants for event names.
    module Events
      # Interaction lifecycle events
      INTERACTION_STARTED = :interaction_started
      INTERACTION_FINISHED = :interaction_finished
      INTERACTION_FAILED = :interaction_failed
      # Mid-turn steering: the user typed while the agent was working and the
      # loop picked the text up at an iteration boundary, injecting it as a
      # user message into the in-flight turn (Codex "Enter injects into the
      # current turn"). Payload: { text:, iteration: }.
      INPUT_INJECTED = :input_injected

      # Status change events
      STATUS_CHANGED = :status_changed

      # Session events
      SESSION_LOADED = :session_loaded
      SESSION_CREATED = :session_created
      SESSION_PERSISTED = :session_persisted

      # Memory events
      MEMORY_LOADED = :memory_loaded
      MEMORY_EXTRACTED = :memory_extracted
      MEMORY_FLUSHED = :memory_flushed

      # Context events
      PROMPT_ASSEMBLED = :prompt_assembled
      CONTEXT_BUDGET_CHECKED = :context_budget_checked

      # Compression events
      COMPRESSION_STARTED = :compression_started
      COMPRESSION_FINISHED = :compression_finished

      # LLM events
      MODEL_CALL_STARTED = :model_call_started
      MODEL_CALL_FINISHED = :model_call_finished
      MODEL_STREAM = :model_stream
      # End of one assistant message (content block). Streamed content deltas
      # carry a +message_id+; this marks that block complete so a consumer can
      # group the deltas that belong together instead of splitting them around
      # tool calls that interleave mid-stream. Mirrors Anthropic's
      # content_block_stop / the AI SDK text-end{id}.
      MESSAGE_COMPLETED = :message_completed

      # Tool events
      TOOL_STARTED = :tool_started
      # Incremental progress from a long-running tool (e.g. summarize_file's
      # per-chunk "summarizing chunk N/M" or shell stdout lines). Emitted from
      # the tool's stream_chunk callback so a tool that runs for minutes
      # without finishing keeps the API event stream alive — the SSE idle
      # watchdog only fires when NOTHING flows, so a genuinely hung run is
      # still caught while a busy-but-silent one heartbeats. Payload:
      # { name:, chunk: }.
      TOOL_PROGRESS = :tool_progress
      TOOL_FINISHED = :tool_finished
      TOOL_APPROVAL_REQUESTED = :tool_approval_requested
      TOOL_APPROVAL_GRANTED = :tool_approval_granted
      TOOL_APPROVAL_DENIED = :tool_approval_denied

      # Job events
      JOB_ENQUEUED = :job_enqueued
      JOB_STARTED = :job_started
      JOB_FINISHED = :job_finished
      JOB_FAILED = :job_failed
      JOB_RETRYING = :job_retrying

      # Background subagent (the `task` tool run in the background, the default).
      # SPAWNED when a backgrounded subagent starts (payload: { task_id:,
      # subagent:, prompt: }); COMPLETED/FAILED when it finishes (payload:
      # { task_id:, subagent:, status:, output:|error: }). These let the CLI
      # surface a completion line and the web UI show in-flight subagents —
      # parity with how background-shell activity surfaces.
      SUBAGENT_SPAWNED = :subagent_spawned
      SUBAGENT_COMPLETED = :subagent_completed
      SUBAGENT_FAILED = :subagent_failed

      # Skill events
      # Emitted when the `skill` tool successfully loads a skill's body into
      # context (the level-2 "Skill 'X' loaded" path), so skill usage is a
      # first-class signal for the recorder/SSE/metrics — parity with how
      # TOOL_STARTED/SUBAGENT_* surface lifecycle. Payload: { name: } — the run
      # association is stamped by the Recorder (run_id), like every other event.
      SKILL_LOADED = :skill_loaded

      # Emitted when a skill is created inline via skill(action: "create") or by
      # the post-turn distill job. Payload: { name:, file_path: }.
      SKILL_CREATED = :skill_created

      # Artifact events
      # Fired by tools that produce a downloadable user-facing file
      # (currently AttachFileTool). Payload: { path:, filename:,
      # content_type:, byte_size: }.
      ARTIFACT_CREATED = :artifact_created
    end
  end
end
