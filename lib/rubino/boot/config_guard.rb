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
      # The Loader normalizes every malformed config shape into a
      # {Config::ConfigError} at the source. The remaining classes here are a
      # defensive backstop: should any raw Psych/IO failure ever slip past the
      # loader (a new shape, a refactor), it still becomes a clean boot abort
      # rather than a double backtrace on every command (CFG-R2).
      def self.load!(loader: Config::Loader.new, stderr: $stderr)
        loader.load
        # LOAD-time schema validation (F8): a HAND-EDITED config.yml with an
        # unknown key or a wrong-typed value used to load SILENTLY (the validator
        # only ran at `config set` time) and only blow up later. Surface those as
        # a clear, NON-FATAL warning here — the boot chokepoint every command
        # already passes through — so the user is told at startup instead of
        # discovering it as a runtime crash / provider 4xx. Never fatal: a
        # warning must not block a usable config, and a probe hiccup is ignored.
        warn_config_issues(loader, stderr)
        nil
      rescue Config::ConfigError, Psych::Exception, SystemCallError, IOError => e
        stderr.puts "rubino: config error — #{e.message}"
        stderr.puts "rubino: fix #{loader.config_path}, restore a backup, or re-run 'rubino setup'."
        exit 1
      end

      # Emits a one-line-per-issue config WARNING to stderr (F8), or nothing when
      # the config is clean. Best-effort — any failure here is swallowed so a
      # validation hiccup can never break boot.
      def self.warn_config_issues(loader, stderr)
        issues = Config::Validator.warnings(loader.raw_config)
        return if issues.empty?

        stderr.puts "rubino: warning: #{loader.config_path} has #{issues.size} " \
                    "config issue#{"s" if issues.size != 1} (run `rubino doctor` for detail):"
        issues.first(5).each { |msg| stderr.puts "rubino:   - #{msg}" }
      rescue StandardError
        nil
      end
    end
  end
end
