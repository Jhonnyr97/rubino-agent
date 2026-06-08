# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Runs
        # POST /v1/sessions/:id/runs
        # Persists a new run for the session and hands it to the executor.
        # The run is reported as "running" immediately; clients tail
        # /v1/runs/:id/events for state transitions.
        #
        # @return [[Integer, Hash]] 201 + run payload.
        # @raise [Rubino::NotFoundError] when the parent session does not exist.
        # @raise [Rubino::ValidationError] when the body fails Schemas::CreateRun.
        class CreateOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts alternate collaborators (session repo, run repo, executor) for tests.
          def initialize(session_repository: nil, run_repository: nil, executor: nil)
            @session_repo = session_repository || ::Rubino::Session::Repository.new
            @run_repo = run_repository || ::Rubino::Run::Repository.new
            @executor = executor || ::Rubino::Run::Executor.new
          end

          def call(request)
            session_id = request.params.fetch("id")
            raise NotFoundError.new("session", session_id) unless @session_repo.find(session_id)

            attrs = request.validate!(Schemas::CreateRun)
            ensure_input_or_attachments!(attrs)
            run = @run_repo.create(
              session_id: session_id,
              input_text: attrs[:input],
              attachments: attrs[:attachments] || [],
              skills: attrs[:skills] || [],
              model: attrs[:model],
              provider: attrs[:provider]
            )

            @executor.start(run)

            [201, serialize(run)]
          end

          private

          # A run needs SOMETHING to act on: either text or at least one
          # attachment (image-only runs are valid — the executor fills in a
          # default prompt). The schema allows a blank/absent `input`, so this
          # is where the "input present OR attachments present" rule lives.
          # Reproduces the prior schema's 422 shape so an empty, attachment-less
          # body still fails as `input: ["must be filled"]`.
          def ensure_input_or_attachments!(attrs)
            return if attrs[:input].to_s.strip != ""
            return if Array(attrs[:attachments]).any?

            raise ValidationError.new(
              "invalid request body",
              details: { errors: { input: ["must be filled"] } }
            )
          end

          def serialize(run)
            {
              id: run[:id],
              session_id: run[:session_id],
              status: "running",
              created_at: run[:created_at]
            }
          end
        end
      end
    end
  end
end
