# frozen_string_literal: true

require "json"
require "logger"

module Rubino
  # Structured JSON-line logger with built-in redaction of sensitive fields.
  #
  #   Rubino.logger.info(event: "api.server.starting", port: 4820)
  #   #=> {"ts":"2026-05-31T...","level":"info","event":"api.server.starting","port":4820}
  #
  # Each level method (#debug, #info, #warn, #error, #fatal) takes **fields
  # and emits one structured line per call.
  #
  # Configuration via environment:
  #   RUBINO_LOG_LEVEL  — debug|info|warn|error|fatal (default: info)
  #   RUBINO_LOG_FORMAT — json|pretty                  (default: json)
  #
  # Redaction: any key whose name (case-insensitive) appears in REDACT_KEYS is
  # replaced with REDACTED at any nesting depth before the line is serialized.
  # This covers tokens, secrets, and raw Authorization headers passing through
  # middleware logs.
  class Logger
    LEVELS = { debug: ::Logger::DEBUG, info: ::Logger::INFO, warn: ::Logger::WARN, error: ::Logger::ERROR,
               fatal: ::Logger::FATAL }.freeze

    # Keys (matched case-insensitively against String form) whose values are
    # replaced with REDACTED before logging. Recursive — applies at any depth.
    REDACT_KEYS = %w[
      access_token refresh_token id_token
      client_secret api_key password secret bearer
      authorization http_authorization
    ].freeze

    # Replacement string written in place of redacted values.
    REDACTED = "[REDACTED]"

    def initialize(io: $stdout, level: ENV.fetch("RUBINO_LOG_LEVEL", "info"),
                   format: ENV.fetch("RUBINO_LOG_FORMAT", "json"))
      @logger = ::Logger.new(io)
      @logger.level = LEVELS.fetch(level.to_sym, ::Logger::INFO)
      @format = format.to_sym
      @logger.formatter = formatter
    end

    # Rebinds the underlying sink to a new IO (or path) WITHOUT replacing the
    # Logger object, so existing references (and the memoized Rubino.logger)
    # keep working. Level and format are preserved.
    #
    # The interactive CLI uses this to route structured JSON lines to a file
    # instead of the terminal $stdout that the raw-mode TUI owns (#125):
    # otherwise a warn/info event (e.g. a network blip during a background
    # subagent) prints raw JSON into the rendered conversation and corrupts the
    # bottom-composer frame. Returns the previous IO so the caller can restore
    # it on exit.
    def reopen(io)
      previous = @logger.instance_variable_get(:@logdev)&.dev
      @logger.reopen(io)
      previous
    end

    LEVELS.each_key do |level|
      define_method(level) do |**fields|
        @logger.public_send(level) { self.class.redact(fields) }
      end
    end

    # Recursively walk a value, masking entries whose key matches REDACT_KEYS.
    # Hash and Array are descended; scalars pass through unchanged.
    # Public because middleware and tests call it directly.
    #
    # @param value [Object] any value (typically Hash, Array, or scalar)
    # @return [Object] same shape as input with sensitive values replaced by REDACTED
    def self.redact(value)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), out|
          out[k] = REDACT_KEYS.include?(k.to_s.downcase) ? REDACTED : redact(v)
        end
      when Array
        value.map { |v| redact(v) }
      else
        value
      end
    end

    private

    def formatter
      if @format == :pretty
        ->(severity, time, _progname, fields) { "[#{time.iso8601}] #{severity.downcase} #{fields.inspect}\n" }
      else
        lambda { |severity, time, _progname, fields|
          "#{JSON.generate({ ts: time.iso8601, level: severity.downcase }.merge(fields))}\n"
        }
      end
    end
  end
end
