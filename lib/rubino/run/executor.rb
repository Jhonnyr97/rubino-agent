# frozen_string_literal: true

require "json"
require_relative "attachment_downloader"
require_relative "../llm/content_builder"
require_relative "../tools/vision_tool"

module Rubino
  module Run
    # Runs an Agent::Runner in a background thread, persisting per-run events
    # via Recorder. Returns immediately so the HTTP handler can respond 201.
    #
    # Per-run wiring done inside the spawned thread:
    #   - Recorder.attach! to mirror EventBus into EventStore + live queue.
    #   - A fresh ApprovalGate per run, published in GateRegistry under run_id
    #     so HTTP decision endpoints can resolve it.
    #   - UI::API instantiated with the gate and recorder so the runner can
    #     ask for approvals / clarifications.
    #   - +ensure+ block always detaches the recorder, unregisters the gate,
    #     and fires the +on_complete+ callback (used by Jobs::Scheduler to
    #     trigger webhook delivery).
    #
    # Metrics: +runs_total+ is incremented once per #start (tagged with
    # +source+, defaulting to +"api"+); +runs_completed_total+ is incremented
    # in the ensure block, tagged with the final +status+ (+completed+ or
    # +failed+).
    #
    # Stop is cooperative via Run::Repository#stop_requested?. The worker
    # spawns a short-tick watcher (#spawn_stop_watcher) that polls that flag
    # and, on observing it, flips the runner's CancelToken via runner.cancel!.
    # The token is the single halt mechanism: the agent loop / LLM stream
    # poll it (CancelToken#check!) and raise Interrupted, which unwinds the
    # turn the same way a chat Ctrl+C does. No second kill path.
    class Executor
      # How often the stop watcher polls the DB stop flag (seconds).
      STOP_POLL_INTERVAL = 0.25
      # Prompt sent to the auxiliary vision model when pre-describing an image
      # for a text-only primary. Verbatim from the reference — broad
      # enough that the description is useful regardless of the user's question.
      VISION_ANALYSIS_PROMPT =
        "Describe everything visible in this image in thorough detail. " \
        "Include any text, code, data, objects, people, layout, colors, " \
        "and any other notable visual information."

      def initialize(repository: nil, recorder_factory: nil, vision_describer: nil)
        @repository = repository || Repository.new
        @recorder_factory = recorder_factory ||
                            lambda { |run_id:, session_id:, event_bus:|
                              Recorder.new(run_id: run_id, session_id: session_id, event_bus: event_bus)
                            }
        # Callable(path) -> description String (or an "Error…" String on
        # failure). Injectable so unit tests don't hit the aux model.
        @vision_describer = vision_describer || method(:default_vision_describe)
      end

      # Parses Run row's persisted attachments_json column (a JSON array of
      # URL strings as sent on the CreateRun body). Returns [] on any
      # malformed input so a broken attachment list never blocks the run.
      def parse_attachment_urls(attachments_json)
        return [] if attachments_json.nil? || attachments_json.to_s.empty?

        parsed = JSON.parse(attachments_json)
        parsed.is_a?(Array) ? parsed : []
      rescue JSON::ParserError
        []
      end

      # Pre-pends an "you have these local files" header to the user input so
      # the model knows the attachments are on disk and doesn't try to webfetch
      # them (binaries crash webfetch — v0.2.5). Pure function (no network) —
      # any vision pre-description is computed upstream and passed in via
      # +descriptions+. Putting the header FIRST anchors small models (MiniMax
      # in particular) — a trailing block was ignored in prod session 33.
      #
      # Per file, mirroring the reference image-routing logic:
      #   - image sent natively (primary sees pixels): a [Image attached at: …]
      #     handle so the model can reference it in follow-up tool calls.
      #   - image on a text-only primary WITH a pre-description: inline the
      #     description so the model has the content without having to choose
      #     to call a tool (the prod failure mode — M2.7 said "no image" / ran
      #     `shell ls`). +descriptions+ maps such paths to their aux output.
      #   - image on a text-only primary WITHOUT a description (aux missing or
      #     errored): an explicit imperative to call `vision`, not shell.
      #   - non-image file: generic pointer; the preamble (PDF → markitdown)
      #     and tool descriptions tell the model which tool fits.
      def augment_input_with_attachments(input_text, paths, native_image_paths: [], descriptions: {})
        return input_text.to_s if paths.nil? || paths.empty?

        native = Array(native_image_paths)
        user_text = input_text.to_s
        if user_text.strip.empty? && paths.any? { |p| LLM::ContentBuilder.image_file?(p) }
          user_text = "What do you see in this image?"
        end

        aux_vision = !Rubino.configuration.auxiliary_vision_config["model"].to_s.empty?
        blocks = paths.filter_map do |p|
          if LLM::ContentBuilder.image_file?(p) && image_by_magic?(p)
            if native.include?(p)
              "[Image attached at: #{p}]"
            elsif descriptions[p]
              "[The user attached an image. Here's what it contains:\n#{descriptions[p]}]\n" \
                "[If you need a closer look, call the `vision` tool with file_path: #{p}.]"
            elsif aux_vision
              # Aux configured but pre-description failed: keep the on-demand
              # `vision` imperative (the tool stays exposed in this case).
              "[The user attached an image at #{p}. Call the `vision` tool with " \
                "file_path: #{p} to see it — do not use shell/ls.]"
            else
              # Gap A: no native vision, no aux vision => the `vision` tool is
              # HIDDEN from the model (Registry#aux_dependency_satisfied?). Do
              # NOT instruct calling a hidden tool; warn instead.
              cls = Attachments::Classify.call(p)
              Attachments::Preamble.no_multimodal_warning(p, cls.mime || "image")
            end
          else
            # Gap B + universal handling + MIME-spoof egress guard: classify by
            # content (magic wins) and render a typed preamble. A file with an
            # image extension whose magic is NOT an image (e.g. a .png-named
            # zip) lands here too via #image_by_magic? above, so it is demoted
            # to its real kind instead of being shipped to native/aux vision.
            # Unsafe/oversize/disallowed => skip+warn.
            attachment_block(p)
          end
        end

        "[Uploaded files — already in your workspace. Do not re-fetch the URLs.]\n" \
          "#{blocks.join("\n\n")}\n\n" \
          "#{user_text}"
      end

      # True only when a file that LOOKS like an image by extension ALSO sniffs
      # as a real image by content (Attachments::Classify, magic wins). Gates
      # the native/aux-vision egress branch: a .png-named zip/text/binary fails
      # here and is demoted to attachment_block (its real typed preamble), so a
      # spoofed extension can never ship raw bytes to the native vision model or
      # the EXTERNAL auxiliary vision model. The safety pipeline (lstat /
      # realpath-confine / size cap) runs inside Classify, so image-extension
      # files now get the same fail-closed checks as every other attachment.
      def image_by_magic?(path)
        cls = Attachments::Classify.call(path)
        cls.safe && cls.kind == :image
      end

      # Classifies a non-image attachment by content (Attachments::Classify --
      # magic wins, fail-closed safety pipeline) and renders the typed preamble
      # (Attachments::Preamble). Returns nil to SKIP the attachment (with a
      # warn) when the safety pipeline rejects it or its kind is disallowed by
      # policy -- never inline/execute an unsafe file. Closes Gap B (archives /
      # documents / binaries get typed guidance instead of a bare `- file:`).
      def attachment_block(path)
        cls = Attachments::Classify.call(path)
        unless cls.safe
          Rubino.logger.warn(event: "run.attachment_skipped", path: path.to_s, reason: cls.reason)
          return nil
        end
        unless Attachments::Policy.allow_kind?(cls.kind)
          Rubino.logger.warn(event: "run.attachment_skipped", path: path.to_s,
                             reason: "kind #{cls.kind} not in allow_kinds")
          return nil
        end
        Attachments::Preamble.for(cls)
      end

      # Spawns the worker thread and returns it immediately.
      # @param run [Hash] row from Run::Repository; +:id+, +:session_id+,
      #   +:input_text+, +:model+, +:provider+ are read.
      # @param on_complete [#call, nil] invoked from the +ensure+ block with
      #   +run_id:+, +session_id:+, +status:+; runs even when the run failed.
      # @return [Thread] the worker thread (caller typically discards it).
      def start(run, on_complete: nil)
        Thread.new do
          run_id = run[:id]
          session_id = run[:session_id]
          # A FRESH bus per run is the isolation boundary: the Recorder and the
          # Runner share THIS instance only, so a run's emit reaches only its own
          # recorder and its detach!/off only removes its own listeners. Without
          # it every run bound the process-global bus and cross-contaminated
          # peers' events/output (architecture audit A1).
          bus = Interaction::EventBus.new
          recorder = @recorder_factory.call(run_id: run_id, session_id: session_id, event_bus: bus)
          gate = ApprovalGate.new
          GateRegistry.register(run_id, gate)
          recorder.attach!
          final_status = "completed"
          stopped      = false
          stop_watcher = nil
          ::Rubino::Metrics.counter(:runs_total, source: run[:source] || "api").increment
          begin
            @repository.mark_running!(run_id)
            # Bind this run's gated UI as the thread-scoped Rubino.ui for the
            # whole worker thread, so tools that look up the global adapter
            # (QuestionTool#ask → clarify.required, TaskTool) hit THIS run's
            # gate/recorder instead of the gate-less process global — without it
            # the `question` tool's prompt is silently dropped and the web run
            # hangs on an unanswerable question.
            ui = UI::API.new(gate: gate, recorder: recorder, session_id: session_id)
            runner = Agent::Runner.new(
              session_id: session_id,
              model_override: run[:model],
              provider_override: run[:provider],
              ui: ui,
              event_bus: bus
            )
            # Bridge the cooperative HTTP stop flag to the runner's cancel
            # token: poll #stop_requested? on a short tick and flip the token
            # so the in-flight loop/stream unwinds via Interrupted. The flag in
            # the closure lets the ensure record the run as "stopped" rather
            # than "completed"/"failed".
            stop_watcher = spawn_stop_watcher(run_id, runner) { stopped = true }
            # Agent::Runner swallows Interrupted and StandardError internally
            # and emits INTERACTION_FAILED on the bus, which Recorder maps to
            # "run.failed". The lifecycle emits INTERACTION_FINISHED on the
            # happy path → "run.completed". Don't re-emit either terminal
            # event here or every run would broadcast two terminal frames
            # (and the web UI would enqueue two title-generation jobs).
            downloaded_paths = AttachmentDownloader.new.fetch_all(
              run_id: run_id,
              urls: parse_attachment_urls(run[:attachments_json])
            )
            # Emit a recorded event so SSE consumers (and post-hoc forensics)
            # can confirm the augment fired and which paths the model saw.
            # Only when something was actually downloaded — a plain chat with
            # no upload has nothing to report, and emitting an empty event just
            # rendered as noise in the timeline. Direct recorder.emit bypasses
            # EventBus, same pattern as approval.required.
            recorder.emit("run.attachments_downloaded", paths: downloaded_paths) if downloaded_paths.any?
            # When the primary model supports vision, image files are passed
            # natively (via ruby_llm `with:`) so the model can ingest the bytes
            # directly. When the primary is text-only, image_paths stays empty
            # and we pre-describe each image with the vision aux NOW, inlining
            # the description into the prompt — so the model has the content
            # without depending on choosing to call the `vision` tool (the prod
            # failure mode in sessions 36/37). The tool stays exposed for
            # on-demand re-inspection either way. Mirrors the reference text-mode
            # _enrich_message_with_vision.
            image_paths_for_native = native_image_paths(downloaded_paths)
            descriptions = preprocess_images_with_vision(
              downloaded_paths, image_paths_for_native, recorder
            )
            Rubino.with_ui(ui) do
              runner.run!(
                augment_input_with_attachments(
                  run[:input_text], downloaded_paths,
                  native_image_paths: image_paths_for_native,
                  descriptions: descriptions
                ),
                image_paths: image_paths_for_native
              )
            end
            @repository.mark_completed!(run_id)
          rescue Rubino::Interrupted
            # Cooperative stop won the race: the watcher flipped the token and
            # the loop unwound via Interrupted. Record "stopped", not "failed"
            # — this was a user-requested halt, not an error. Re-raise to a
            # failed terminal state only if the token flipped for some other
            # reason than a stop request (shouldn't happen in the API path).
            if stopped || @repository.stop_requested?(run_id)
              final_status = "stopped"
              @repository.mark_stopped!(run_id)
              recorder.emit("run.stopped", {})
            else
              final_status = "failed"
              safe_mark_failed(run_id, "interrupted")
              safe_emit_failed(recorder, "interrupted")
            end
          rescue SystemExit, Interrupt, SignalException
            # Process is shutting down — re-raise so systemd / Puma can drain.
            # Mark the run as failed first so it isn't left stuck in "running".
            final_status = "failed"
            safe_mark_failed(run_id, "agent process terminated")
            safe_emit_failed(recorder, "agent process terminated")
            raise
          rescue Exception => e # rubocop:disable Lint/RescueException
            # Catch Exception (not just StandardError) — user-tool LoadError /
            # SyntaxError / NoMemoryError can propagate from threads inside the
            # runner via Thread#join, and without this the worker silently dies
            # and the run is left as "running" forever (the recorder never sees
            # INTERACTION_FAILED so the SSE stream also never gets a terminal
            # frame). Emit run.failed directly via the recorder as a safety net
            # in case the lifecycle didn't get a chance to.
            final_status = "failed"
            Rubino.logger.error(event: "run.exception", run_id: run_id, error: e.class.name, message: e.message)
            safe_mark_failed(run_id, "#{e.class}: #{e.message}")
            safe_emit_failed(recorder, "#{e.class}: #{e.message}")
          ensure
            stop_watcher&.kill
            recorder.detach!
            GateRegistry.unregister(run_id)
            ::Rubino::Metrics.counter(:runs_completed_total, status: final_status).increment
            on_complete&.call(run_id: run_id, session_id: session_id, status: final_status)
          end
        end
      end

      private

      # Polls the run's stop flag on a short tick and, on observing it, flips
      # the runner's CancelToken (the single halt mechanism). Yields once after
      # the cancel so the caller can record that this was a stop, then exits.
      # Returns the watcher Thread; the worker kills it in its ensure block.
      def spawn_stop_watcher(run_id, runner)
        Thread.new do
          loop do
            sleep STOP_POLL_INTERVAL
            next unless @repository.stop_requested?(run_id)

            runner.cancel!
            # The CancelToken only halts the loop/stream at a poll point. If the
            # worker is parked inside ApprovalGate#await (queue.pop, up to the
            # configured wait bound — default 15 min) it never reaches one, so
            # wake the gate too — it raises Interrupted in the awaiting thread
            # and frees the worker. Without this a cancelled/abandoned approval
            # holds a Solid Queue thread for the whole wait window (W1).
            GateRegistry.fetch(run_id)&.cancel!
            yield if block_given?
            break
          end
        rescue StandardError => e
          # A DB hiccup in the watcher must never take down the run; the worst
          # case is the stop is observed a tick later or not at all.
          Rubino.logger.error(event: "run.stop_watcher_error", run_id: run_id,
                              error: e.class.name, message: e.message)
        end
      end

      # Returns the subset of paths that are images AND can be ingested
      # natively by the current primary model. Empty when either condition
      # fails — in which case the `vision` tool path takes over.
      def native_image_paths(paths)
        return [] if paths.nil? || paths.empty?
        return [] unless Rubino.configuration.model_supports_vision?

        paths.select { |p| LLM::ContentBuilder.image_file?(p) }
      end

      # For images NOT sent natively (text-only primary), ask the vision aux to
      # describe each up-front. Returns { path => description } for the ones that
      # succeeded; the augment inlines them. No-op (empty hash) when no aux
      # vision model is configured — the augment then falls back to an explicit
      # "call the `vision` tool" imperative instead. Emits forensic events so a
      # missing/failed pre-description is visible post-hoc (same reason
      # run.attachments_downloaded exists).
      def preprocess_images_with_vision(paths, native, recorder)
        return {} if Rubino.configuration.auxiliary_vision_config["model"].to_s.empty?

        text_only_images = paths.select { |p| LLM::ContentBuilder.image_file?(p) } - Array(native)
        text_only_images.each_with_object({}) do |path, acc|
          result = @vision_describer.call(path).to_s
          if result.start_with?("Error")
            recorder&.emit("run.vision_preprocess_failed", path: path, error: result.slice(0, 300))
          else
            recorder&.emit("run.vision_preprocessed", path: path, chars: result.length)
            acc[path] = result
          end
        end
      end

      # Default describer: routes through the same VisionTool the model can call
      # on demand, so pre-description and on-demand inspection share one path.
      def default_vision_describe(path)
        Tools::VisionTool.new.call("file_path" => path, "question" => VISION_ANALYSIS_PROMPT)
      end

      # mark_failed! can itself raise (DB locked, etc). The whole point of the
      # outer rescue is to leave the row in a terminal state — if even that
      # fails, log and move on; the watchdog in EventsOperation will catch it.
      def safe_mark_failed(run_id, message)
        @repository.mark_failed!(run_id, error: message.to_s.slice(0, 500))
      rescue StandardError => e
        Rubino.logger.error(event: "run.mark_failed_error", run_id: run_id, error: e.class.name, message: e.message)
      end

      # Recorder may already be detached (race with the ensure block) — emit is
      # best-effort. The DB row is the authoritative source of truth; SSE is a
      # convenience.
      def safe_emit_failed(recorder, message)
        recorder&.emit("run.failed", error: message.to_s.slice(0, 500))
      rescue StandardError => e
        Rubino.logger.error(event: "run.emit_failed_error", error: e.class.name, message: e.message)
      end
    end
  end
end
