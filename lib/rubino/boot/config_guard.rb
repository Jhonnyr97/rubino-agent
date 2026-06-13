# frozen_string_literal: true

module Rubino
  module Boot
    # Loads configuration at process startup, turning a malformed/corrupt
    # config.yml into a clean, actionable boot abort instead of a raw Ruby +
    # Psych double backtrace (CFG-1).
    #
    # The entrypoint (`exe/rubino`) calls {Config::Loader#load} for EVERY
    # command, before Thor dispatch. Any {Config::ConfigError} (or a
    # {Psych::SyntaxError} that escapes the loader) used to propagate all the
    # way out of `exe/rubino:16`, so a single typo in config.yml killed the
    # process with a stack trace — even `rubino doctor`, whose graceful
    # corruption handler (#259) was never reached because boot died first.
    #
    # {.load!} runs the load behind a rescue that writes a single-line
    # diagnostic (what's wrong + the config path + how to fix it) to $stderr
    # and exits non-zero — boot abort, not exception, mirroring
    # {EncryptionKey.validate!}. doctor's own handling still works: doctor
    # re-loads via the Loader and reports corruption itself, so a clean boot
    # here does not mask it.
    module ConfigGuard
      def self.load!(loader: Config::Loader.new, stderr: $stderr)
        loader.load
        nil
      rescue Config::ConfigError, Psych::SyntaxError => e
        stderr.puts "rubino: config error — #{e.message}"
        stderr.puts "rubino: fix #{loader.config_path}, restore a backup, or re-run 'rubino setup'."
        exit 1
      end
    end
  end
end
