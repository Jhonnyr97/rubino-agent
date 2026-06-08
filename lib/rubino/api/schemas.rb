# frozen_string_literal: true

require "dry-schema"

Dry::Schema.load_extensions(:json_schema)

module Rubino
  module API
    # dry-schema definitions for HTTP request bodies. Validation runs only at
    # the HTTP boundary (via Request#validate!); domain code downstream assumes
    # types are already coerced. Each constant maps to a single endpoint.
    module Schemas
      # POST /v1/sessions
      CreateSession = Dry::Schema.JSON do
        optional(:title).maybe(:string)
        optional(:parent_id).maybe(:string)
      end

      # POST /v1/sessions/:id/runs
      # `input` is optional at the schema level so an image-only run (a file
      # with no accompanying text) is accepted: the executor substitutes a
      # default prompt when the text is blank but an image is attached. The
      # "input present OR attachments present" rule is enforced in
      # Operations::Runs::CreateOperation (dry-schema has no cross-field rule
      # and we don't pull in dry-validation just for this).
      CreateRun = Dry::Schema.JSON do
        optional(:input).maybe(:string)
        optional(:attachments).array(:string)
        optional(:skills).array(:string)
        optional(:model).maybe(:string)
        optional(:provider).maybe(:string)
      end

      # POST /v1/runs/:run_id/approvals/:approval_id
      # Keep in sync with UI::API::APPROVE_DECISIONS — the approve values plus
      # the explicit "deny" (one-off) and "deny_always" (persists a
      # permissions:deny rule) forms the closed set of decisions the gate
      # understands. `always` is a BACK-COMPAT ALIAS for `always_command`
      # (existing web clients post `always`); `always_prefix`/`always_command`
      # are the explicit forms. New values are additive — old clients keep working.
      DecideApproval = Dry::Schema.JSON do
        required(:decision).filled(
          :string,
          included_in?: %w[once session always always_prefix always_command deny deny_always]
        )
      end

      # POST /v1/runs/:run_id/clarifications/:clarify_id
      DecideClarification = Dry::Schema.JSON do
        required(:response).filled(:string)
      end

      # PUT /v1/skills/:name
      ToggleSkill = Dry::Schema.JSON do
        required(:enabled).filled(:bool)
      end

      # PUT /v1/mode — string instead of symbol because JSON has no symbol
      # type; the operation normalises via Modes.set.
      UpdateMode = Dry::Schema.JSON do
        required(:mode).filled(:string, included_in?: Rubino::Modes::ALL.map(&:to_s))
      end

      # POST /v1/jobs
      CreateCronJob = Dry::Schema.JSON do
        required(:name).filled(:string)
        required(:schedule).filled(:string)
        required(:prompt).filled(:string)
        optional(:skills).array(:string)
        optional(:model).maybe(:string)
        optional(:provider).maybe(:string)
        optional(:deliver).filled(:string, included_in?: %w[local webhook])
      end

      # PATCH /v1/jobs/:id
      UpdateCronJob = Dry::Schema.JSON do
        optional(:name).filled(:string)
        optional(:schedule).filled(:string)
        optional(:prompt).filled(:string)
        optional(:skills).array(:string)
        optional(:model).maybe(:string)
        optional(:provider).maybe(:string)
        optional(:deliver).filled(:string, included_in?: %w[local webhook])
        optional(:enabled).filled(:bool)
      end

      # POST /v1/oauth/providers/:id/connect
      ConnectProvider = Dry::Schema.JSON do
        required(:redirect_uri).filled(:string)
        optional(:scopes).array(:string)
      end

      # POST /v1/oauth/providers/:id/callback
      CallbackProvider = Dry::Schema.JSON do
        required(:code).filled(:string)
        required(:state).filled(:string)
        required(:expected_state).filled(:string)
        required(:code_verifier).filled(:string)
        required(:redirect_uri).filled(:string)
      end
    end
  end
end
