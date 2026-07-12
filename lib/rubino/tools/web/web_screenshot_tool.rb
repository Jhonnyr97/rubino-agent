# frozen_string_literal: true

require "fileutils"

module Rubino
  module Tools
    # Capture a PNG screenshot of a web page (JS-rendered via ferrum + Chrome)
    # and attach it as a downloadable artifact for the user. The image is a
    # USER-FACING ARTIFACT, not fed to the model, so it works regardless of
    # model vision support.
    class WebScreenshotTool < Base
      redaction_profile :none

      def config_key
        "web"
      end

      description "Capture a PNG screenshot of a web page (renders JavaScript) and " \
                  "attach it as a downloadable artifact for the user. " \
                  "Use when the user needs to SEE a page (a form, a button to click), " \
                  "not just its text."

      param :url, desc: "The URL to screenshot"
      param :full_page, desc: "Capture the full scrollable page (default false = viewport only)", required: false

      def execute(url:, full_page: false)
        begin
          safe = Rubino::Security::UrlSafety.validate!(url, allow_private: allow_private_network?)
        rescue Rubino::Security::UrlSafety::BlockedURLError => e
          return { output: "Refused for safety: #{e.message}" }
        end
        uri = safe[:uri]

        unless Rubino::Web::JsRenderer.available?
          return {
            output: "Headless screenshots need the optional `ferrum` gem and a Chrome/Chromium " \
                    "binary. Install with `rubino setup` (re-run install.sh with the JS extra), " \
                    "or run `gem install ferrum`."
          }
        end

        out_dir = File.join(Rubino.home_path, "tool-results")
        FileUtils.mkdir_p(out_dir)

        host = uri.host.to_s.gsub(/[^a-zA-Z0-9._-]/, "_")
        path_slug = uri.path.to_s.gsub(/[^a-zA-Z0-9._-]/, "_")[0, 60]
        ts = Time.now.strftime("%Y%m%d%H%M%S")
        png_path = File.join(out_dir, "screenshot-#{host}-#{path_slug}-#{ts}.png")

        result = Rubino::Web::JsRenderer.screenshot(uri.to_s, png_path, full_page: full_page)
        return { output: "Screenshot failed (renderer error)." } unless result

        size = File.size(png_path)
        filename = File.basename(png_path)

        {
          output: "Captured screenshot of #{url} (#{size} bytes).",
          metrics: "#{size} bytes",
          artifact: {
            path: png_path,
            filename: filename,
            content_type: "image/png",
            byte_size: size
          }
        }
      end

      private

      def allow_private_network?
        Rubino.configuration.dig("tools", "webfetch", "allow_private_network") != false
      end
    end
  end
end
