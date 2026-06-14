# frozen_string_literal: true

module Rubino
  module Documents
    # Shared decompression-bomb / runaway-conversion guard for the in-process
    # converters (#S4-1). The 25 MB on-disk `max_file_bytes` is trivially
    # defeated by zip compression: a 100 KB .docx expands to 34 MB of XML and
    # ~1M paragraphs, driving rubino to ~1.4 GB RSS / ~100 s of uninterruptible
    # CPU before the output cap (applied only AFTER full conversion) throws the
    # result away. The fix caps BEFORE/DURING conversion.
    #
    # A Budget is created once per conversion and threaded into the converter's
    # per-element loop. Each iteration calls #tick(elements:, bytes:), which:
    #   - honors the cancel_token (raises Rubino::Interrupted so the turn is
    #     interruptible mid-conversion, not just at chunk boundaries);
    #   - enforces an element/page/row count ceiling (paragraphs, rows, pages,
    #     slides) so a structural bomb stops after N units;
    #   - enforces a decompressed-bytes ceiling (accumulated extracted/parsed
    #     text) so an expand bomb stops once it has produced a few x the output
    #     cap of text;
    #   - enforces a wall-clock budget so any pathological slow path (a single
    #     huge element, a quadratic gem call) still bails in bounded time.
    # On any ceiling, it raises CapExceeded -> shell-hint. All caps are
    # generous relative to a real document but tiny relative to a bomb.
    module Limits
      module_function

      # Defaults. Overridable via config (attachments.policy.convert_*), so an
      # operator can loosen them, but the secure defaults bound a bomb hard.
      #   - MAX_ELEMENTS: paragraphs/rows/pages/slides processed before bail.
      #   - MAX_DECOMPRESSED_BYTES: accumulated extracted text bytes; ~5 MB is
      #     ~50 x the 100 KB inline budget and far below the 34 MB an expand
      #     bomb produces.
      #   - WALL_CLOCK_SECONDS: total conversion budget.
      #   - TICK_INTERVAL: how often (in elements) to read the clock, so the
      #     time check itself is cheap in the hot loop.
      DEFAULT_MAX_ELEMENTS         = 50_000
      DEFAULT_MAX_DECOMPRESSED     = 5_000_000 # ~5 MB of extracted text
      DEFAULT_WALL_CLOCK_SECONDS   = 15.0
      TICK_INTERVAL                = 256

      # PRE-OPEN zip-bomb guard for the OOXML converters (docx/xlsx/pptx). The
      # decisive cost of a zip-expand bomb is paid the instant the gem opens the
      # file: it reads the (e.g. 34 MB) decompressed XML entry into a String and
      # builds the full Nokogiri DOM (~1.4 GB RSS) BEFORE yielding a single
      # paragraph -- so per-element ticking alone is too late. The central
      # directory carries each entry's UNCOMPRESSED size, readable without
      # decompressing, so we sum the relevant XML entries first and bail to the
      # shell-hint before the gem inflates anything. `glob` matches the content
      # entries that hold the document body (word/document*.xml, xl/**, ppt/**),
      # which is where a structural bomb lives. Raises CapExceeded over cap.
      def guard_zip!(path, budget, globs)
        require "zip"
        total = 0
        Zip::File.open(path) do |zip|
          zip.each do |entry|
            next unless globs.any? { |g| File.fnmatch?(g, entry.name, File::FNM_PATHNAME) }

            total += entry.size.to_i
            if total > budget.max_decompressed_bytes
              raise CapExceeded, "decompressed zip size cap (#{budget.max_decompressed_bytes} bytes) exceeded"
            end
          end
        end
      rescue CapExceeded
        raise
      rescue StandardError
        # A malformed/unreadable zip is not our concern here -- let the gem-level
        # converter handle it (it degrades to nil/shell-hint). Don't block a
        # valid file because the pre-check tripped on an exotic zip layout.
        nil
      end

      # A no-op budget for direct converter calls / tests that don't thread a
      # real budget. Caps are effectively unbounded but cancellation still
      # works if a token is supplied.
      def null_budget
        Budget.new(
          max_elements: Float::INFINITY,
          max_decompressed_bytes: Float::INFINITY,
          wall_clock_seconds: Float::INFINITY
        )
      end

      # Builds a Budget from config, falling back to the secure defaults.
      def budget(cancel_token: nil)
        cfg = policy_config
        Budget.new(
          max_elements: int(cfg["convert_max_elements"], DEFAULT_MAX_ELEMENTS),
          max_decompressed_bytes: int(cfg["convert_max_decompressed_bytes"], DEFAULT_MAX_DECOMPRESSED),
          wall_clock_seconds: flt(cfg["convert_wall_clock_seconds"], DEFAULT_WALL_CLOCK_SECONDS),
          cancel_token: cancel_token
        )
      end

      def policy_config
        Rubino.configuration.dig("attachments", "policy") || {}
      rescue StandardError
        {}
      end

      def int(value, default)
        value.nil? ? default : Integer(value)
      rescue ArgumentError, TypeError
        default
      end

      def flt(value, default)
        value.nil? ? default : Float(value)
      rescue ArgumentError, TypeError
        default
      end

      # Per-conversion resource counter. Not thread-safe by design: a single
      # conversion runs on one thread; the cancel_token IS the cross-thread
      # signal and is itself lock-free/monotonic.
      class Budget
        attr_reader :elements, :bytes, :max_decompressed_bytes

        def initialize(max_elements:, max_decompressed_bytes:, wall_clock_seconds:, cancel_token: nil)
          @max_elements = max_elements
          @max_decompressed_bytes = max_decompressed_bytes
          @wall_clock = wall_clock_seconds
          @deadline = monotonic + wall_clock_seconds
          @cancel_token = cancel_token
          @elements = 0
          @bytes = 0
          @since_clock = 0
        end

        # Account for one (or more) processed units and `bytes` of extracted
        # text, then enforce every cap. Call once per element in the converter's
        # hot loop. Raises Rubino::Interrupted on cancel, CapExceeded on any cap.
        def tick(elements: 1, bytes: 0)
          @elements += elements
          @bytes += bytes
          @since_clock += elements

          # Cancellation first: a cancelled turn must abort even mid-bomb.
          raise Rubino::Interrupted if @cancel_token&.cancelled?

          raise CapExceeded, "element count cap (#{@max_elements}) exceeded" if @elements > @max_elements
          if @bytes > @max_decompressed_bytes
            raise CapExceeded, "decompressed size cap (#{@max_decompressed_bytes} bytes) exceeded"
          end

          # Reading a clock per element is measurable in a tight 1M-iteration
          # loop; sample it every TICK_INTERVAL elements instead.
          return unless @since_clock >= TICK_INTERVAL

          @since_clock = 0
          raise CapExceeded, "wall-clock budget (#{format("%.0f", @wall_clock)}s) exceeded" if monotonic > @deadline
        end

        # Account for `count` extracted bytes WITHOUT advancing the element count
        # (e.g. a raw whole-file read in html/csv/json/xml/plain). Still checks
        # the byte ceiling, the clock, and cancellation.
        def add_bytes(count)
          tick(elements: 0, bytes: count)
        end

        private

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
