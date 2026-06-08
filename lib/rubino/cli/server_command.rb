# frozen_string_literal: true

module Rubino
  module CLI
    # Starts the HTTP API server (Rack + Puma).
    class ServerCommand
      def initialize(options = {})
        @options = options
      end

      def execute
        # Fail fast: a missing/malformed encryption key blows up on the first
        # OAuth hit otherwise, with the listener already accepting traffic.
        Boot::EncryptionKey.validate!

        # The fake LLM provider is dev-only — it replays canned YAML scenarios
        # instead of talking to a real LLM, so booting the API with it on by
        # accident would silently serve fake answers to real clients. Refuse
        # to start unless the operator explicitly opted in.
        guard_fake_provider!

        port = (@options[:port] || ENV.fetch("RUBINO_API_PORT", 4820)).to_i
        # Loopback by default (#69); a routable bind is an explicit opt-in.
        host = @options[:host] || ENV.fetch("RUBINO_API_HOST", "127.0.0.1")
        api_key = @options[:api_key] || ENV.fetch("RUBINO_API_KEY", nil)

        # When TLS is enabled (RUBINO_TLS=1 or a cert already exists), make
        # sure a self-signed cert+key exist under RUBINO_HOME and serve over
        # HTTPS. The web client pins this cert. Local dev / fake leave the
        # toggle unset and no cert, so the listener stays plain HTTP.
        tls_cert = tls_key = nil
        if API::TLS.enabled?
          API::TLS.ensure_cert!(host: host)
          tls_cert = API::TLS.cert_path
          tls_key  = API::TLS.key_path
        end

        register_metric_descriptions!

        # Without this the tool registry stays empty, Lifecycle#load_tools
        # returns [], no `tools: [...]` is sent on the wire, and the model
        # has no choice but to roleplay tools in markdown. The CLI path
        # (ChatCommand#ensure_setup!) registers tools the same way; both
        # entry points need the same line.
        Rubino::Tools::Registry.register_defaults! if Rubino::Tools::Registry.all.empty?

        # Instantiate the shared agent registry at boot so the `task` tool can
        # resolve subagents (explore/general) over /v1 — the API path uses the
        # same delegation flow as the CLI. Memoized on Rubino.agent_registry.
        Rubino.agent_registry

        router = API::Router.new
        router.get    "/v1/health",                 to: API::Operations::HealthOperation
        router.get    "/v1/metrics",                to: API::Operations::MetricsOperation
        router.get    "/v1/sessions",               to: API::Operations::Sessions::IndexOperation
        router.post   "/v1/sessions",               to: API::Operations::Sessions::CreateOperation
        router.get    "/v1/sessions/:id",           to: API::Operations::Sessions::ShowOperation
        router.delete "/v1/sessions/:id",           to: API::Operations::Sessions::DeleteOperation
        router.post   "/v1/sessions/:id/runs",      to: API::Operations::Runs::CreateOperation
        router.get    "/v1/runs/:id/events",        to: API::Operations::Runs::EventsOperation
        router.post   "/v1/runs/:id/stop",          to: API::Operations::Runs::StopOperation
        router.post   "/v1/sessions/:id/retry",     to: API::Operations::Sessions::RetryOperation
        router.post   "/v1/sessions/:id/undo",      to: API::Operations::Sessions::UndoOperation
        router.post   "/v1/runs/:run_id/approvals/:approval_id",         to: API::Operations::Approvals::DecideOperation
        router.post   "/v1/runs/:run_id/clarifications/:clarify_id",     to: API::Operations::Clarifications::DecideOperation
        router.get    "/v1/skills",                 to: API::Operations::Skills::ListOperation
        router.put    "/v1/skills/:name",           to: API::Operations::Skills::ToggleOperation
        router.get    "/v1/mode",                   to: API::Operations::Mode::ShowOperation
        router.put    "/v1/mode",                   to: API::Operations::Mode::UpdateOperation
        router.get    "/v1/models",                 to: API::Operations::Models::ListOperation
        router.get    "/v1/files",                  to: API::Operations::Files::ReadOperation
        router.post   "/v1/files",                  to: API::Operations::Files::UploadOperation
        router.get    "/v1/jobs",                   to: API::Operations::CronJobs::ListOperation
        router.post   "/v1/jobs",                   to: API::Operations::CronJobs::CreateOperation
        router.get    "/v1/jobs/:id",               to: API::Operations::CronJobs::ShowOperation
        router.patch  "/v1/jobs/:id",               to: API::Operations::CronJobs::UpdateOperation
        router.delete "/v1/jobs/:id",               to: API::Operations::CronJobs::DeleteOperation
        router.post   "/v1/jobs/:id/pause",         to: API::Operations::CronJobs::PauseOperation
        router.post   "/v1/jobs/:id/resume",        to: API::Operations::CronJobs::ResumeOperation
        router.post   "/v1/jobs/:id/trigger",       to: API::Operations::CronJobs::TriggerOperation
        router.get    "/v1/memory",                 to: API::Operations::Memory::IndexOperation
        router.get    "/v1/memory/stats",           to: API::Operations::Memory::StatsOperation
        router.delete "/v1/memory/:id",             to: API::Operations::Memory::DeleteOperation
        router.get    "/v1/tasks",                   to: API::Operations::Tasks::IndexOperation
        router.get    "/v1/tasks/:id",               to: API::Operations::Tasks::ShowOperation
        router.post   "/v1/tasks/:id/stop",          to: API::Operations::Tasks::StopOperation
        router.get    "/v1/oauth/providers",                  to: API::Operations::OAuth::Providers::ListOperation
        router.post   "/v1/oauth/providers/:id/connect",      to: API::Operations::OAuth::Providers::ConnectOperation
        router.post   "/v1/oauth/providers/:id/callback",     to: API::Operations::OAuth::Providers::CallbackOperation
        router.get    "/v1/oauth/connections",                to: API::Operations::OAuth::Connections::ListOperation
        router.delete "/v1/oauth/connections/:id",            to: API::Operations::OAuth::Connections::DisconnectOperation

        ::Rubino::OAuth::Registry.load_from_config!
        Jobs::Scheduler.instance.load_all!
        # Drains any webhook delivery that was persisted as pending before a
        # prior crash/restart. See Jobs::WebhookDelivery#resume_pending!.
        Jobs::Scheduler.instance.resume_pending_webhooks!

        Rubino::API::Server.new(
          port: port,
          host: host,
          api_key: api_key,
          router: router,
          tls_cert: tls_cert,
          tls_key: tls_key
        ).start!
      end

      private

      def guard_fake_provider!
        provider = Rubino.configuration.model_provider
        return unless provider.to_s == "fake"
        return if ENV["RUBINO_ALLOW_FAKE"] == "1"

        $stderr.puts "fake provider is dev-only — set RUBINO_ALLOW_FAKE=1 to opt in."
        exit(1)
      end

      # HELP text is looked up by Metrics.counter/.histogram at first-touch, so
      # this must run before any metric is incremented (i.e. before the Rack
      # stack is built). When adding a new Metrics.counter/.histogram anywhere
      # in the codebase, add its HELP line here — the metrics_help_spec asserts
      # every registered metric carries a description.
      def register_metric_descriptions!
        Metrics.describe(:http_requests_total, "Total HTTP requests handled, labelled by method/path/status.")
        Metrics.describe(:http_request_duration_seconds, "HTTP request duration in seconds.")
        Metrics.describe(:cron_fires_total, "Number of cron jobs fired, labelled by job and outcome.")
        Metrics.describe(:webhook_deliveries_total, "Webhook deliveries attempted, labelled by outcome.")
        Metrics.describe(:oauth_token_exchanges_total, "OAuth token exchanges, labelled by provider and outcome.")
        Metrics.describe(:runs_total, "Runs started, labelled by source.")
        Metrics.describe(:runs_completed_total, "Total number of runs that have completed (success+failure+cancelled).")
        Metrics.describe(:skills_loaded_total, "Number of times a skill was successfully loaded via the `skill` tool.")
        Metrics.describe(:skills_created_total, "Number of new skills observed by the registry on a re-scan (disk-diff signal; no creation tool exists).")
      end
    end
  end
end
