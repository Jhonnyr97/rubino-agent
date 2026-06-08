# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Tasks
        # Wire shapes for background-subagent (`task`) entries.
        #
        # #summary powers the list endpoint — id/subagent/prompt/status/timing
        # plus a short result preview, never the full body. #detail adds the
        # complete result (success) or error (failure). The Entry struct carries
        # Time objects and a live Thread/Runner; only the serializable fields are
        # surfaced.
        module Serializer
          module_function

          RESULT_PREVIEW = 200

          def summary(entry)
            {
              id: entry.id,
              subagent: entry.subagent,
              prompt: entry.prompt,
              status: entry.status.to_s,
              started_at: iso(entry.started_at),
              elapsed_seconds: elapsed(entry),
              result_summary: preview(entry.result)
            }
          end

          def detail(entry)
            summary(entry).merge(
              finished_at: iso(entry.finished_at),
              result: entry.result,
              error: entry.error
            )
          end

          def iso(time)
            time&.utc&.iso8601
          end

          # Wall-clock seconds: to finish if done, else to now for a live task.
          def elapsed(entry)
            return nil unless entry.started_at

            ((entry.finished_at || Time.now) - entry.started_at).round(3)
          end

          def preview(result)
            return nil if result.nil?

            str = result.to_s
            str.length > RESULT_PREVIEW ? "#{str[0, RESULT_PREVIEW]}…" : str
          end
        end
      end
    end
  end
end
