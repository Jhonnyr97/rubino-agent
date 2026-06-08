# frozen_string_literal: true

require "fileutils"
require "yaml"

module Rubino
  module Jobs
    module Handlers
      # Variant B — deterministic post-turn skill distillation.
      #
      # Enqueued from Interaction::Lifecycle#enqueue_post_turn_jobs alongside
      # ExtractMemoryJob. The GATE is fully deterministic (no model call):
      #   - the run produced a non-empty final assistant answer (succeeded), AND
      #   - the turn used >= TOOL_THRESHOLD tool calls (mirrors the reference "5+"), AND
      #   - no existing skill already covers the work (kept simple here:
      #     no skill whose name/description shares a salient keyword with the
      #     user's task — a fresh skills dir always passes).
      # Only on a gate-PASS do we spend ONE auxiliary-model call to distil the
      # just-finished transcript into a SKILL.md candidate, which we then write.
      # So: +1 LLM call per gate-pass, 0 otherwise.
      class DistillSkillJob
        TOOL_THRESHOLD = Integer(ENV.fetch("RA_DISTILL_TOOL_THRESHOLD", "5"))

        NAME_RE = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

        DISTILL_SYSTEM = <<~SYS
          You distil a just-finished agent task into a REUSABLE skill, or decline.
          You are given the user's task and a transcript of the tools the agent ran
          and its final answer. If — and only if — the work was a complex, multi-step,
          REPEATABLE procedure that would help future similar tasks, output a skill.
          If it was trivial, one-off, or not generalizable, decline.

          Output ONLY a JSON object, no prose:
          {"create": true, "name": "<kebab-case, <=64 chars>",
           "description": "<one line: what it's for and WHEN it applies>",
           "body": "<markdown: # Title then the proven step-by-step instructions, commands, pitfalls — generalized, not hard-coded to this one input>"}
          or {"create": false, "reason": "<why not skill-worthy>"}
        SYS

        def perform(payload)
          session_id = payload[:session_id] || payload["session_id"]
          return unless session_id

          messages = Session::Store.new.for_session(session_id)
          return unless gate_passes?(messages)

          candidate = distill(messages)
          return unless candidate && candidate["create"] == true

          write_skill(candidate)
        rescue StandardError => e
          warn "DistillSkillJob: #{e.class}: #{e.message}"
          nil
        end

        private

        # Deterministic gate — NO model call here.
        def gate_passes?(messages)
          succeeded?(messages) &&
            tool_count(messages) >= TOOL_THRESHOLD &&
            !already_covered?(messages)
        end

        def succeeded?(messages)
          final = messages.reverse.find { |m| m.role == "assistant" && !m.content.to_s.strip.empty? }
          !final.nil?
        end

        def tool_count(messages)
          messages.count { |m| m.role == "tool" }
        end

        # "No skill already covering it": if the registry is empty, never covered.
        # Otherwise, covered when the user's task shares a salient keyword with an
        # existing skill's name/description. Deterministic, cheap, no model call.
        def already_covered?(messages)
          skills = registry.all
          return false if skills.empty?

          task = first_user_text(messages).to_s.downcase
          task_words = task.scan(/[a-z]{4,}/).to_set
          skills.any? do |s|
            hay = "#{s.name} #{s.description}".downcase
            hay.scan(/[a-z]{4,}/).any? { |w| task_words.include?(w) }
          end
        end

        def first_user_text(messages)
          messages.find { |m| m.role == "user" }&.content
        end

        # The single auxiliary-model call (counts as the +1 LLM call).
        def distill(messages)
          transcript = build_transcript(messages)
          response = LLM::AuxiliaryClient.new.call(
            task: "summarize",
            messages: [
              { role: "system", content: DISTILL_SYSTEM },
              { role: "user", content: transcript }
            ]
          )
          extract_json(response.content.to_s)
        end

        def build_transcript(messages)
          parts = []
          messages.each do |m|
            case m.role
            when "user"
              parts << "USER TASK:\n#{m.content}"
            when "tool"
              parts << "TOOL #{m.respond_to?(:tool_name) ? m.tool_name : ''}: #{m.content.to_s[0, 400]}"
            when "assistant"
              next if m.content.to_s.strip.empty?

              parts << "ASSISTANT: #{m.content.to_s[0, 800]}"
            end
          end
          parts.join("\n\n")[0, 8000]
        end

        def extract_json(text)
          start = text.index("{")
          return nil unless start

          depth = 0
          (start...text.length).each do |i|
            depth += 1 if text[i] == "{"
            if text[i] == "}"
              depth -= 1
              return JSON.parse(text[start..i]) if depth.zero?
            end
          end
          nil
        rescue JSON::ParserError
          nil
        end

        def write_skill(candidate)
          name = candidate["name"].to_s.strip
          desc = candidate["description"].to_s.tr("\n", " ").strip
          body = candidate["body"].to_s
          return unless valid?(name, desc, body)
          return if registry.find(name) # don't overwrite

          dir = File.join(skills_write_dir, name)
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "SKILL.md")
          content = +"---\nname: #{name}\ndescription: #{yaml_scalar(desc)}\n---\n\n#{body}"
          content << "\n" unless content.end_with?("\n")
          File.write(path, content)

          Metrics.counter(:skills_created_total).increment
          Rubino.active_event_bus&.emit(
            Interaction::Events::SKILL_CREATED, name: name, file_path: path
          )
          path
        end

        def valid?(name, desc, body)
          name.match?(NAME_RE) && name.length <= 64 &&
            !desc.empty? && desc.length <= 1024 && !body.strip.empty?
        end

        def yaml_scalar(text)
          %("#{text.gsub('"', '\\"')}")
        end

        def skills_write_dir
          dir = (Rubino.configuration.dig("skills", "paths") || [".rubino/skills"]).first
          File.expand_path(dir.to_s)
        end

        def registry
          @registry ||= Skills::Registry.new
        end
      end
    end
  end
end

require "set"

# Register the handler
Rubino::Jobs::Registry.register(
  "DistillSkillJob", Rubino::Jobs::Handlers::DistillSkillJob
)
