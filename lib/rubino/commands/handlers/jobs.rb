# frozen_string_literal: true

module Rubino
  module Commands
    module Handlers
      # The `/jobs` in-chat window into the PERSISTENT jobs queue (#187),
      # extracted from Commands::Executor (batch B) — the queue the agent itself
      # feeds mid-session (DistillSkillJob after tool-heavy turns, memory
      # extraction), distinct from the in-process /agents subagents. Read-mostly:
      # `process`/`worker` stay CLI-only (they are daemons, not session actions).
      #
      #   /jobs        → status counts + the recent-jobs table (the SAME
      #                  rendering as `rubino jobs list` — JobsCommand.render_list)
      #   /jobs <id>   → one job in full (attempts, payload, last error);
      #                  short-id prefixes resolve, like /memory show
      class Jobs
        # Render order for the /jobs counts header (#187) — lifecycle order, not
        # the arbitrary GROUP BY order (any unknown status is appended).
        STATUS_ORDER = %w[queued running completed failed dead].freeze

        def initialize(ui:)
          @ui = ui
        end

        def handle_jobs(arguments)
          id = arguments.to_s.strip.split(/\s+/).first
          id.nil? ? show_jobs_list : show_job_detail(id)
        end

        private

        def show_jobs_list
          queue  = Rubino::Jobs::Queue.new
          counts = queue.counts
          if counts.empty?
            @ui.info("No jobs yet — the agent enqueues background work " \
                     "(skill distillation, memory extraction) as you chat.")
            return
          end

          ordered = (STATUS_ORDER & counts.keys) + (counts.keys - STATUS_ORDER)
          @ui.info(ordered.map { |status| "#{counts[status]} #{status}" }.join("  ·  "))
          CLI::JobsCommand.render_list(queue.list, ui: @ui)
          @ui.info("/jobs <id> for detail   ·   `rubino jobs process` runs pending ones now")
        end

        def show_job_detail(id)
          job = Rubino::Jobs::Queue.new.find(id)
          if job.nil?
            @ui.error("no job with id #{id}.")
            @ui.info("List them with /jobs")
            return
          end

          @ui.info("#{job[:id][0..7]}  #{job[:type]}  ·  #{job[:status]}")
          @ui.info("  attempts  #{job[:attempts]}/#{job[:max_attempts]}")
          @ui.info("  run_at    #{job[:run_at]}")
          @ui.info("  created   #{job[:created_at]}")
          @ui.info("  payload   #{truncate(job[:payload_json], 200)}")
          error = job[:last_error].to_s
          @ui.error(error) unless error.empty?
        end

        def truncate(text, max)
          s = text.to_s.gsub(/\s+/, " ").strip
          s.length > max ? "#{s[0, max - 1]}…" : s
        end
      end
    end
  end
end
