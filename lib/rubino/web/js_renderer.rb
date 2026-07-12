# frozen_string_literal: true

module Rubino
  module Web
    # Headless-browser fallback for JavaScript-rendered pages (SPAs). The static
    # Net::HTTP fetch in WebFetchTool returns the raw server response; for a
    # client-rendered app that is an empty shell (`<div id="root"></div>`), so
    # readability has nothing to extract. This module drives a real Chromium via
    # the DevTools protocol (the `ferrum` gem), lets the page's JS run, and hands
    # back the fully-rendered DOM, which then flows through the SAME extraction
    # path as a static fetch (one backend, two front-ends).
    #
    # `ferrum` is an OPTIONAL dependency (never bundled): it is `require`d lazily
    # inside begin/rescue LoadError exactly like the Documents converters, so the
    # gem loads and every other web fetch works with ferrum absent. `available?`
    # returns false until the user installs it (and a Chrome/Chromium binary) on
    # demand. See install.sh for the opt-in prompt.
    #
    # The canonical ferrum procedure is copied verbatim from the official docs:
    #   browser = Ferrum::Browser.new(...)
    #   browser.go_to(url); browser.network.wait_for_idle; browser.body
    # ensure browser.quit   (must run or Chrome zombies)
    module JsRenderer
      module_function

      # Communication + idle-wait timeout (seconds). Ferrum's default is 5, too
      # tight for JS-heavy pages; 15 mirrors the static fetch's 30s ceiling while
      # staying responsive.
      TIMEOUT = 15
      # How long to wait for the Chrome process itself to come up on launch.
      PROCESS_TIMEOUT = 30

      # System Chrome/Chromium locations probed when neither BROWSER_PATH nor a
      # rubino-downloaded shell is present. ferrum also auto-detects a binary on
      # PATH, so this list is a best-effort head start, not exhaustive.
      SYSTEM_CHROME_CANDIDATES = [
        # macOS
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
        # Linux (common package paths)
        "/usr/bin/google-chrome",
        "/usr/bin/google-chrome-stable",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/snap/bin/chromium"
      ].freeze

      # True when the ferrum gem can be loaded. Kept separate from
      # `chrome_available?` so callers can distinguish "gem missing" (install
      # ferrum) from "no browser binary" (install Chrome) in diagnostics.
      def available?
        require "ferrum"
        true
      rescue LoadError
        false
      end

      # True when we can point ferrum at a concrete Chrome binary, OR one is on
      # PATH for ferrum to auto-detect.
      def chrome_available?
        !chrome_path.nil? || !ENV["PATH"].to_s.empty?
      end

      # Render `url` in headless Chrome and return the post-JS HTML, or nil on
      # any failure (missing gem/browser, timeout, crash) so the caller falls
      # back to the static result instead of erroring the turn.
      #
      # SSRF: the caller (webfetch) has already applied its URL policy — the SAME
      # UrlSafety check the static fetch uses — before we get here, so we only
      # render a URL that already passed it. We add NO further in-process
      # filtering: a headless browser re-resolves DNS and follows redirects itself,
      # so in-process checks are best-effort theatre (cf. CVE-2026-42592), and for
      # a single-user LOCAL agent the addresses in play are the user's own
      # localhost/LAN. A real boundary (network isolation / egress proxy) is the
      # deployment's job, not this method's.
      def render(url, timeout: TIMEOUT)
        return nil unless available?

        require "ferrum"
        browser = new_browser(timeout)
        begin
          browser.go_to(url)
          # Returns false (does NOT raise) if connections are still pending at
          # the timeout — we take whatever DOM has rendered so far regardless.
          browser.network.wait_for_idle(timeout: timeout)
          browser.body
        ensure
          browser.quit
        end
      rescue StandardError => e
        Rubino.logger&.warn(event: "webfetch.js_render.failed",
                            error: "#{e.class}: #{e.message}")
        nil
      end

      # Capture a PNG screenshot of `url` in headless Chrome and write it to
      # `path`. Returns the path on success, nil on any failure (missing
      # gem/browser, timeout, crash). The caller (web_screenshot tool) applies
      # UrlSafety BEFORE calling — the SAME rationale as #render.
      def screenshot(url, path, full_page: false, timeout: TIMEOUT)
        return nil unless available?

        require "ferrum"
        browser = new_browser(timeout)
        begin
          browser.go_to(url)
          browser.network.wait_for_idle(timeout: timeout)
          browser.screenshot(path: path, full: full_page)
          path
        ensure
          browser.quit
        end
      rescue StandardError => e
        Rubino.logger&.warn(event: "webfetch.js_screenshot.failed",
                            error: "#{e.class}: #{e.message}")
        nil
      end

      def new_browser(timeout)
        options = {
          headless: true,
          timeout: timeout,
          process_timeout: PROCESS_TIMEOUT,
          # Do NOT disable the Chrome sandbox by default: on a normal user
          # machine it is a real security boundary. disable-gpu / dev-shm are
          # harmless and avoid container/headless glitches.
          browser_options: browser_options
        }
        path = chrome_path
        options[:browser_path] = path if path
        ::Ferrum::Browser.new(**options)
      end

      # Chrome command-line flags passed through ferrum's :browser_options hash
      # (flag name => nil for valueless flags, the documented shape).
      def browser_options
        { "disable-gpu": nil, "disable-dev-shm-usage": nil }
      end

      # Resolution order (highest priority first):
      #   1. a rubino-downloaded chrome-headless-shell under RUBINO_HOME
      #   2. $BROWSER_PATH (ferrum's own override env)
      #   3. a known system Chrome/Chromium location
      #   4. nil -> ferrum auto-detects a binary on PATH
      def chrome_path
        downloaded_chrome ||
          executable(ENV.fetch("BROWSER_PATH", nil)) ||
          SYSTEM_CHROME_CANDIDATES.find { |p| File.executable?(p) }
      end

      # A chrome-headless-shell downloaded on demand into RUBINO_HOME by the
      # opt-in installer. Glob because Chrome-for-Testing nests the binary under
      # a platform/version directory.
      def downloaded_chrome
        base = File.join(Rubino.home_path, "chrome-headless-shell")
        return nil unless File.directory?(base)

        Dir.glob(File.join(base, "**", "chrome-headless-shell"))
           .find { |p| File.executable?(p) }
      end

      def executable(path)
        p = path.to_s.strip
        return nil if p.empty?

        File.executable?(p) ? p : nil
      end
    end
  end
end
