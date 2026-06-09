# frozen_string_literal: true

require "tmpdir"
require "open3"

module Rubino
  module Interaction
    # Grabs an image from the system clipboard and writes it to a temp PNG so it
    # can be attached to a turn's image_paths (the native vision slot). Mirrors
    # Claude Code's Cmd+V image paste from the terminal.
    #
    # Platform tools, best-effort and in priority order:
    #   - macOS  : `pngpaste` (brew install pngpaste)
    #   - Wayland: `wl-paste` (wl-clipboard)
    #   - X11    : `xclip`
    #
    # Returns the temp file path on success, or nil when no tool is available or
    # the clipboard holds no image. #unavailable_reason explains a nil so the CLI
    # can show an actionable hint instead of a silent no-op.
    module ClipboardImage
      module_function

      # Ordered [tool, argv-builder] candidates. The builder takes the dest path
      # and returns the argv that writes a PNG of the clipboard image to it.
      def commands(dest)
        case RbConfig::CONFIG["host_os"]
        when /darwin/
          [["pngpaste", [dest]]]
        when /linux/
          [
            ["wl-paste", ["-t", "image/png", "--no-newline"]], # writes to stdout
            ["xclip", ["-selection", "clipboard", "-t", "image/png", "-o"]]
          ]
        else
          []
        end
      end

      # Saves the clipboard image to a temp PNG and returns its path, or nil.
      def save_to_tempfile
        dest = File.join(Dir.tmpdir, "rubino_clip_#{Process.pid}_#{rand(1_000_000)}.png")
        capture(dest) ? dest : nil
      end

      # Runs the first available tool. macOS pngpaste writes the file directly;
      # the Linux tools write PNG bytes to stdout which we redirect to +dest+.
      def capture(dest)
        commands(dest).each do |tool, args|
          next unless which(tool)

          if tool == "pngpaste"
            _out, = Open3.capture2e(tool, *args)
          else
            out, status = Open3.capture2(tool, *args)
            File.binwrite(dest, out) if status.success? && !out.empty?
          end
          return true if File.file?(dest) && File.size(dest).positive?
        end
        false
      rescue StandardError
        false
      end

      # Human-readable reason a paste produced nothing, for the CLI hint.
      def unavailable_reason
        case RbConfig::CONFIG["host_os"]
        when /darwin/
          "no image on the clipboard, or `pngpaste` isn't installed (brew install pngpaste)."
        when /linux/
          "no image on the clipboard, or neither `wl-paste` nor `xclip` is installed."
        else
          "clipboard image paste isn't supported on this platform."
        end
      end

      def which(tool)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, tool)
          File.executable?(path) && !File.directory?(path)
        end
      end
    end
  end
end
