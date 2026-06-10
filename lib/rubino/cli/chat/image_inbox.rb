# frozen_string_literal: true

module Rubino
  module CLI
    module Chat
      # The REPL's image-attachment inbox (attach an image from the terminal),
      # extracted from ChatCommand (#17).
      #
      # Attachments live in #pending_image_paths between the prompt read and
      # the turn; run_turn consumes + clears them via #take! so each image is
      # sent once into the native vision slot (image_paths →
      # Lifecycle#execute → adapter `with:`).
      class ImageInbox
        # Builds the [text, image_paths] pair for a one-shot turn. Pulls @image /
        # dropped-path tokens out of the prompt (so they hit the vision slot, not
        # the literal text) and prepends any paths given via --image. Flag paths
        # are expanded the same way as in-line tokens; a flag path that isn't a
        # readable image is reported and skipped rather than silently dropped.
        #
        # Every candidate then passes the SAME secure-by-default attachment gate
        # as the server/run path (Attachments::Classify + Policy, via
        # ImageInput#attachment_error) — a policy rejection is a clean one-line
        # error BEFORE any network call, not five provider retries (#98).
        def self.resolve_oneshot(query, flag_values)
          flag_paths = Array(flag_values).map { |p| Interaction::ImageInput.expand(p) }
          flag_paths.each do |p|
            next if LLM::ContentBuilder.image_file?(p) && File.file?(p)

            warn "rubino: ignoring --image #{p} (not a readable image file)"
          end
          valid_flags = flag_paths.select { |p| LLM::ContentBuilder.image_file?(p) && File.file?(p) }
          valid_flags.each do |p|
            reason = Interaction::ImageInput.attachment_error(p)
            raise Rubino::Error, "--image #{p}: #{reason}" if reason
          end

          result = Interaction::ImageInput.parse(query, existing: valid_flags)
          if (rejection = result.rejected.first)
            raise Rubino::Error, "#{rejection[:path]}: #{rejection[:reason]}"
          end

          [result.text, result.image_paths]
        end

        def pending_image_paths
          @pending_image_paths ||= []
        end

        # Consumes the turn's queued image attachments (the native vision slot)
        # and resets so they're attached exactly once, not re-sent next turn.
        def take!
          paths = pending_image_paths
          @pending_image_paths = []
          paths
        end

        # Seeds the interactive pending-images inbox from --image/-i flag paths
        # (#160), through the SAME attachment gate every other staging surface
        # uses (Attachments::Classify + Policy via ImageInput#attachment_error).
        # A bad flag path warns and is skipped — interactive startup must not die
        # on it the way one-shot raises. Staged images show the usual indicator
        # and are covered by /clear-images, as documented.
        def stage_flag_images(flag_values, ui)
          Array(flag_values).each do |raw|
            path = Interaction::ImageInput.expand(raw)
            unless LLM::ContentBuilder.image_file?(path) && File.file?(path)
              ui.warning("not attached — #{raw}: not a readable image file")
              next
            end
            if (reason = Interaction::ImageInput.attachment_error(path))
              ui.warning("not attached — #{File.basename(path)}: #{reason}")
              next
            end
            pending_image_paths << path unless pending_image_paths.include?(path)
          end
          show_image_indicator(ui, pending_image_paths) unless pending_image_paths.empty?
        end

        # Parses the line for image references (@image, dropped/quoted/escaped
        # path), moves any into @pending_image_paths and returns the cleaned text.
        # Non-image references are left in the text (current behaviour). Shows an
        # in-prompt indicator for whatever is now attached. A candidate the
        # attachment policy rejects (oversize / spoofed extension / unsafe) is
        # dropped with a one-line warning instead of being shipped (#98).
        def extract_images!(input, ui)
          result = Interaction::ImageInput.parse(input, existing: pending_image_paths)
          result.rejected.each do |rejection|
            ui.warning("not attached — #{File.basename(rejection[:path])}: #{rejection[:reason]}")
          end
          newly = result.image_paths - pending_image_paths
          @pending_image_paths = result.image_paths
          show_image_indicator(ui, newly) unless newly.empty?
          result.text
        end

        # Handles the REPL-local image commands. Returns true when it consumed the
        # input (so the main loop should `next`), false otherwise.
        #
        #   /paste         — grab an image from the clipboard into image_paths
        #   /clear-images  — drop all pending attachments
        # rubocop:disable Naming/PredicateMethod -- "did I consume the line", not a pure predicate
        def handle_image_command(input, ui)
          case input.strip.downcase
          when "/clear-images", "/clear-image"
            if pending_image_paths.empty?
              ui.info("No attached images to clear.")
            else
              ui.info("Cleared #{pending_image_paths.size} attached image(s).")
              @pending_image_paths = []
            end
            true
          when "/paste"
            paste_clipboard_image(ui)
            true
          else
            false
          end
        end
        # rubocop:enable Naming/PredicateMethod

        private

        def paste_clipboard_image(ui)
          path = Interaction::ClipboardImage.save_to_tempfile
          unless path
            ui.warning("Clipboard paste failed: #{Interaction::ClipboardImage.unavailable_reason}")
            return
          end

          # Same universal attachment gate as @image/dropped/--image paths (#98):
          # a clipboard capture that violates policy (e.g. oversize) is dropped
          # with a clear warning, never shipped to the provider.
          if (reason = Interaction::ImageInput.attachment_error(path))
            ui.warning("not attached — #{File.basename(path)}: #{reason}")
            return
          end

          pending_image_paths << path unless pending_image_paths.include?(path)
          show_image_indicator(ui, [path])
        end

        # In-prompt indicator of attached image(s), Claude-Code style.
        def show_image_indicator(ui, newly)
          newly.each { |p| ui.status("[image: #{File.basename(p)}]") }
          total = pending_image_paths.size
          ui.status("#{total} image#{"s" if total != 1} attached — " \
                    "sent with your next message (/clear-images to drop).")
        end
      end
    end
  end
end
