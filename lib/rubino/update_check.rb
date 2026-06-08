# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "time"
require "fileutils"

module Rubino
  # Boot-time "new version available" notice + the `rubino update` mechanics.
  #
  # Two decoupled concerns, mirroring how `gh`/update-notifier do it:
  #
  #   * SHOW (sync, zero network): `notice_from_cache` reads
  #     <RUBINO_HOME>/update_check.json and returns a one-line notice only when
  #     the cached `latest` is a valid Gem::Version strictly greater than the
  #     running VERSION. Pure local read — cannot slow boot, works offline.
  #
  #   * REFRESH (out-of-band): `refresh_async_if_stale` spawns a detached,
  #     fully-rescued Thread (≈1.5s timeout) that GETs RubyGems and rewrites the
  #     cache for the NEXT boot. It is never joined, so this boot never blocks.
  #     Gated to once/24h, TTY-only, not-in-CI, and skipped entirely when
  #     RUBINO_NO_UPDATE_CHECK is set.
  #
  # The whole feature no-ops until rubino-agent is actually published: RubyGems
  # currently returns {"version":"unknown"}, and "unknown" / non-semver / nil /
  # any network error are all treated as "no info" → no notice.
  module UpdateCheck
    LATEST_URL    = "https://rubygems.org/api/v1/versions/rubino-agent/latest.json"
    GEM_NAME      = "rubino-agent"
    CACHE_FILE    = "update_check.json"
    CHECK_INTERVAL = 24 * 60 * 60 # 24h, like gh/Homebrew
    NET_TIMEOUT   = 1.5

    module_function

    # ---- SHOW (pure local read) -------------------------------------------

    # One-line dim notice when a newer version is cached, else nil.
    def notice_from_cache
      latest = cached_latest
      return nil unless newer?(latest)

      "▸ rubino v#{latest} available — run `rubino update`"
    end

    # ---- REFRESH (out-of-band, never awaited) -----------------------------

    # Refresh the cache in a detached thread iff enabled and stale. Returns the
    # spawned Thread (tests can join it) or nil when gated out. The caller never
    # joins it on the boot path, so this boot is never slowed.
    def refresh_async_if_stale
      return nil unless checks_enabled?
      return nil unless stale?

      Thread.new do
        latest = fetch_latest
        write_cache(latest) if latest
      rescue StandardError
        # Offline, DNS, TLS, JSON garbage, FS — silent. The cache is left as-is,
        # so a transient failure simply shows no notice.
        nil
      end
    end

    # ---- network ----------------------------------------------------------

    # The latest published version string, or nil on failure / "unknown" /
    # non-semver. Synchronous + short-timeout; callers that must not block run
    # it on a detached thread (refresh_async_if_stale).
    def fetch_latest
      uri = URI(LATEST_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = NET_TIMEOUT
      http.read_timeout = NET_TIMEOUT

      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = "Rubino/#{Rubino::VERSION}"

      res = http.request(req)
      return nil unless res.is_a?(Net::HTTPSuccess)

      version = JSON.parse(res.body)["version"].to_s
      semver?(version) ? version : nil
    rescue StandardError
      nil
    end

    # ---- cache ------------------------------------------------------------

    def cache_path
      File.join(Rubino::Config::Loader.default_home_path, CACHE_FILE)
    end

    def cached_latest
      return nil unless File.exist?(cache_path)

      JSON.parse(File.read(cache_path))["latest"]
    rescue StandardError
      nil
    end

    # Atomic write (temp + rename) so a crashed refresh never leaves a torn file.
    def write_cache(latest)
      dir = File.dirname(cache_path)
      FileUtils.mkdir_p(dir)
      tmp = "#{cache_path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.generate("checked_at" => Time.now.utc.iso8601, "latest" => latest))
      File.rename(tmp, cache_path)
    rescue StandardError
      nil
    end

    def clear_cache!
      File.delete(cache_path) if File.exist?(cache_path)
    rescue StandardError
      nil
    end

    # ---- gating -----------------------------------------------------------

    # All must hold (mirrors gh): no opt-out env, interactive TTY, not CI.
    def checks_enabled?
      ENV["RUBINO_NO_UPDATE_CHECK"].to_s.strip.empty? &&
        $stdout.tty? &&
        ENV["CI"].to_s.strip.empty?
    end

    # True when the cache is missing or its checked_at is older than 24h.
    def stale?
      return true unless File.exist?(cache_path)

      checked_at = JSON.parse(File.read(cache_path))["checked_at"]
      Time.now.utc - Time.parse(checked_at) >= CHECK_INTERVAL
    rescue StandardError
      true
    end

    # ---- update mechanics -------------------------------------------------

    # How rubino was installed: :gem when a matching RubyGems spec is loaded,
    # else :source (dev checkout / built from source / vendored).
    def install_method
      installed_gem_version(GEM_NAME) ? :gem : :source
    end

    def installed_gem_version(name)
      Gem::Specification.find_by_name(name).version.to_s
    rescue Gem::MissingSpecError, StandardError
      nil
    end

    # Argv form (no shell) + active interpreter via Gem.ruby → updates the right
    # install on a multi-Ruby machine and is injection-safe.
    def gem_update_command
      [Gem.ruby, "-S", "gem", "update", GEM_NAME]
    end

    # ---- version helpers --------------------------------------------------

    # X.Y / X.Y.Z[.pre] — strict enough to reject "unknown" and other garbage.
    def semver?(str)
      !!(str.to_s =~ /\A\d+\.\d+(\.\d+)?([-.][0-9A-Za-z.-]+)?\z/)
    end

    # latest is a valid version strictly greater than the running VERSION.
    def newer?(latest)
      return false unless semver?(latest)

      Gem::Version.new(latest) > Gem::Version.new(Rubino::VERSION)
    rescue ArgumentError
      false
    end
  end
end
