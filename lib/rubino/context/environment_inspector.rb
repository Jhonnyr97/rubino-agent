# frozen_string_literal: true

require "rbconfig"
require "date"

module Rubino
  module Context
    # Builds the "[Environment]" block injected into every system prompt.
    #
    # Probes the host once per process for the static bits (OS, ruby/python
    # versions, external utilities on PATH) and asks for the dynamic bits
    # (date, cwd, git branch) on every build. The static cache survives the
    # length of the process — long enough for an HTTP server's lifetime,
    # short enough that a `gem install` between deploys repopulates it.
    #
    # The goal is a concrete, honest description of the *actual* runtime the
    # model is talking to. If markitdown isn't installed in the VM image, we
    # don't list it — the agent will then ask the user instead of confidently
    # invoking a binary that doesn't exist.
    class EnvironmentInspector
      # External CLI tools we probe by default. The list mixes hard
      # dependencies (git, ruby) and useful-but-optional binaries the agent
      # may want to shell out to (markitdown, pandoc, …). Anything not
      # found on PATH is silently dropped — see #available_utilities.
      DEFAULT_UTILITIES = %w[
        git gh rg jq curl wget
        ruby python3 node npm bundle
        docker psql sqlite3 redis-cli
        ffmpeg pandoc markitdown pdftotext tesseract soffice qpdf
      ].freeze

      class << self
        # Process-wide cache of the static fields. Reset via #reset_cache!
        # from specs.
        def cache
          @cache ||= {}
        end

        def reset_cache!
          @cache = {}
        end
      end

      def initialize(extra_utilities: [], cwd: nil, clock: -> { Time.now })
        @extra_utilities = Array(extra_utilities).map(&:to_s)
        @cwd = cwd
        @clock = clock
      end

      # Returns the assembled [Environment] block, or nil if the caller
      # disabled it at the config layer (PromptAssembler decides — this
      # class always renders when asked).
      def render
        lines = []
        lines << "[Environment]"
        lines << "- Today's date: #{today}"
        lines << "- Platform: #{platform}"
        lines << "- Shell: #{shell}"
        lines << "- Working dir: #{working_dir}"
        git = git_description
        lines << "- Git: #{git}" if git
        lines << "- Runtimes: #{runtimes}"
        utilities = available_utilities
        lines << "- Available CLI tools on PATH: #{utilities.join(", ")}" if utilities.any?
        docs = document_formats
        if docs.any?
          lines << "- Document reading: the `read_attachment` tool converts these formats " \
                   "to Markdown in-process (no external binary needed): #{docs.join(", ")}"
        end
        lines.join("\n")
      end

      # The CORE document formats readable in-process via read_attachment
      # (driven by which optional extraction gems loaded). Advertised so the
      # model knows it can read a docx/pdf even when no `markitdown` binary
      # exists on PATH -- closing the gap this file's own comment describes.
      def document_formats
        self.class.cache[:document_formats] ||= begin
          Rubino::Documents::Registry.available_formats
        rescue StandardError
          []
        end
      end

      # Public for spec inspection. The list is sorted to keep the prompt
      # stable turn-to-turn (otherwise reordering would invalidate the
      # provider-side prompt cache).
      def available_utilities
        probes = (DEFAULT_UTILITIES + @extra_utilities).uniq
        self.class.cache[:utilities] ||= probes.select { |bin| on_path?(bin) }.sort
      end

      private

      def today
        @clock.call.strftime("%Y-%m-%d")
      end

      def platform
        self.class.cache[:platform] ||= begin
          host_os = RbConfig::CONFIG["host_os"]
          arch    = RbConfig::CONFIG["host_cpu"]
          os_name =
            case host_os
            when /darwin/  then "macOS"
            when /linux/   then linux_distro || "Linux"
            when /mswin|mingw|cygwin/ then "Windows"
            else host_os
            end
          "#{os_name} (#{arch})"
        end
      end

      def linux_distro
        return nil unless File.readable?("/etc/os-release")

        pretty = File.read("/etc/os-release", encoding: "UTF-8").lines.find { |l| l.start_with?("PRETTY_NAME=") }
        pretty&.split("=", 2)&.last&.strip&.delete('"')
      rescue StandardError
        nil
      end

      def shell
        self.class.cache[:shell] ||= File.basename(ENV["SHELL"] || "sh")
      end

      def working_dir
        @cwd || Dir.pwd
      rescue StandardError
        "(unavailable)"
      end

      def git_description
        dir = working_dir
        return nil unless File.directory?(File.join(dir, ".git"))

        branch = `git -C #{shellescape(dir)} rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
        branch.empty? ? "repo (detached HEAD)" : "repo on branch #{branch}"
      rescue StandardError
        nil
      end

      def runtimes
        self.class.cache[:runtimes] ||= begin
          parts = []
          parts << "Ruby #{RUBY_VERSION}"
          py = probe_version("python3", "--version")
          parts << "Python #{py}" if py
          node = probe_version("node", "--version")
          parts << "Node #{node.sub(/\Av/, "")}" if node
          parts.join(", ")
        end
      end

      def probe_version(bin, flag)
        return nil unless on_path?(bin)

        out = `#{shellescape(bin)} #{flag} 2>&1`.strip
        out.split.last
      rescue StandardError
        nil
      end

      def on_path?(bin)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, bin)
          File.executable?(path) && !File.directory?(path)
        end
      end

      def shellescape(str)
        str.to_s.gsub(%r{([^A-Za-z0-9_\-.,:/@\n])}, "\\\\\\1")
      end
    end
  end
end
