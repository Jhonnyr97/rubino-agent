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
      # shell-hint before the gem inflates anything.
      #
      # The sum runs WITHOUT File::FNM_PATHNAME so `*` crosses `/` -- a bomb
      # planted at a nested, non-standard path (e.g. xl/worksheets/deep/sheet.xml,
      # reachable via the workbook .rels Target, or ppt/slides/extra/s.xml) is
      # caught just like one at the canonical depth. The pre-fix glob used
      # FNM_PATHNAME, so `*` stopped at `/` and a deep bomb summed to zero and
      # slipped through to roo's inflate (#337). Globs still scope the sum to the
      # body parts (word/document*.xml, xl/**, ppt/**) so a large thumbnail/media
      # blob doesn't false-positive. Raises CapExceeded over cap.
      #
      # #350: scoping to the OOXML body globs alone missed formats whose read
      # paths live OUTSIDE that prefix -- notably an ODS, whose `content.xml`
      # sits at the archive ROOT (not under xl/) yet is routed through the same
      # roo/xlsx converter. Such a bomb summed to ZERO under `xl/**` and slipped
      # to roo's inflate. The converter now passes the ACTUAL read-path globs per
      # format (ODS adds `content.xml`/root `*.xml`). As a backstop we ALSO sum
      # the WHOLE archive's uncompressed bytes against a (looser) total cap, so a
      # bomb at any unforeseen path is still bounded even if no body glob matches
      # it. The two caps are independent: the per-glob sum keeps the body tight,
      # the whole-archive backstop guarantees no out-of-glob path is unbounded.
      def guard_zip!(path, budget, globs)
        require "zip"
        scoped = 0
        archive = 0
        archive_cap = total_archive_cap(budget)
        Zip::File.open(path) do |zip|
          zip.each do |entry|
            size = entry.size.to_i
            archive += size
            if archive > archive_cap
              raise CapExceeded, "decompressed zip size cap (whole-archive #{archive_cap} bytes) exceeded"
            end

            # No FNM_PATHNAME: `*` matches across `/` so nested-path bombs sum.
            next unless globs.any? { |g| File.fnmatch?(g, entry.name) }

            scoped += size
            if scoped > budget.max_decompressed_bytes
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

      # Whole-archive backstop cap (#350). Looser than the per-glob body cap so a
      # legit doc with large media/thumbnails the converter never reads doesn't
      # false-positive, but still finite so an out-of-glob bomb can't be
      # unbounded. Defaults to ARCHIVE_CAP_MULTIPLIER x the body cap (∞ stays ∞).
      ARCHIVE_CAP_MULTIPLIER = 20

      def total_archive_cap(budget)
        body = budget.max_decompressed_bytes
        return body if body == Float::INFINITY

        body * ARCHIVE_CAP_MULTIPLIER
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
