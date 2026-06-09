# frozen_string_literal: true

require "spec_helper"

# Locks down the contract that every metric the server exposes carries a
# Prometheus HELP line. Without this, /v1/metrics renders `# HELP <name> <name>`
# for any counter/histogram that the boot path forgot to describe, which is
# both noisy and breaks downstream tooling that filters on description content.
RSpec.describe "Prometheus HELP coverage" do
  # The set of metrics the server actually increments at runtime. Anything
  # added to lib/ must also be touched here AND described in
  # CLI::ServerCommand#register_metric_descriptions! — the assertion below
  # catches missing descriptions.
  REGISTERED_METRICS = %i[
    http_requests_total
    http_request_duration_seconds
    cron_fires_total
    webhook_deliveries_total
    oauth_token_exchanges_total
    runs_total
    runs_completed_total
    skills_loaded_total
    skills_created_total
  ].freeze

  before do
    Rubino::Metrics.reset!
    Rubino::CLI::ServerCommand.new.send(:register_metric_descriptions!)
  end

  after { Rubino::Metrics.reset! }

  it "describes every metric the server registers" do
    REGISTERED_METRICS.each do |name|
      # Touch a counter or histogram so the metric is actually instantiated.
      if name == :http_request_duration_seconds
        Rubino::Metrics.histogram(name).observe(0.01)
      else
        Rubino::Metrics.counter(name).increment
      end
    end

    output = Rubino::Metrics.render
    REGISTERED_METRICS.each do |name|
      expect(output).to match(/^# HELP #{Regexp.escape(name.to_s)} .+/),
                        "expected /v1/metrics output to include a non-empty HELP line for #{name}"
    end
  end

  it "ensures no registered metric falls back to its name as the HELP text" do
    REGISTERED_METRICS.each do |name|
      Rubino::Metrics.counter(name).increment if name != :http_request_duration_seconds
      Rubino::Metrics.histogram(name).observe(0.01) if name == :http_request_duration_seconds
    end

    Rubino::Metrics.each do |metric|
      expect(metric.help).not_to eq(metric.name.to_s),
                                 "#{metric.name} has no description — add it to ServerCommand#register_metric_descriptions!"
      expect(metric.help.to_s).not_to be_empty
    end
  end
end
