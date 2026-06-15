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

        # Common 4+-char English / dev words that carry no topical signal. A
        # single one of these overlapping ("file", "code", "this", "with",
        # "rails" sitting in a skill description) must NOT count as coverage —
        # that single-shared-word rule (#368) over-suppressed legitimately
        # distinct tasks ("deploy workflow for Rails" suppressed by the word
        # "rails" appearing in ruby-expert's description).
        STOPWORDS = %w[
          this that with from your into about make made using used will would
          should could have has had been being does done when then than them
          they their there here what which while also some such only just like
          want need help please thing things file files code line lines step
          steps task tasks work works call calls user users data text time
          name names show list find each both more most less very much many
          good well over under again same other else type kind sort
        ].to_set.freeze

        # Coverage requires MEANINGFUL overlap (#368), not a single shared word:
        # a name-level match, OR salient stopword-filtered tokens overlapping by
        # at least COVERAGE_JACCARD with at least MIN_SHARED_SALIENT shared tokens.
        COVERAGE_JACCARD = 0.4
        MIN_SHARED_SALIENT = 2

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
          Rubino.logger.warn(event: "jobs.distill_skill.error", error_class: e.class.name, message: e.message)
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

        # "No skill already covering it": empty registry -> never covered. Else
        # covered only on a MEANINGFUL overlap (#368) — the skill NAME's salient
        # tokens are wholly present in the task (name-level match), or the
        # stopword-filtered salient tokens overlap by Jaccard >= COVERAGE_JACCARD
        # AND share >= MIN_SHARED_SALIENT tokens. A lone common word can no longer
        # suppress a distinct task. Deterministic, cheap, no model call.
        def already_covered?(messages)
          skills = registry.all
          return false if skills.empty?

          task_tokens = salient_tokens(first_user_text(messages).to_s)
          return false if task_tokens.empty?

          skills.any? do |s|
            name_tokens = s.name.to_s.downcase.split(/[^a-z0-9]+/).reject(&:empty?).to_set
            next true if name_level_match?(name_tokens, task_tokens)

            skill_tokens = salient_tokens("#{s.name} #{s.description}")
            meaningful_overlap?(task_tokens, skill_tokens)
          end
        end

        # Stopword-filtered salient tokens (4+ chars) of a piece of text.
        def salient_tokens(text)
          text.downcase.scan(/[a-z]{4,}/).reject { |w| STOPWORDS.include?(w) }.to_set
        end

        # The skill's name tokens (>=2, all salient) are all present in the task —
        # a strong, name-level signal that the task is what the skill is for.
        def name_level_match?(name_tokens, task_tokens)
          salient = name_tokens.reject { |w| w.length < 4 || STOPWORDS.include?(w) }.to_set
          salient.size >= 2 && salient.subset?(task_tokens)
        end

        # Jaccard similarity over salient tokens, gated by an absolute floor of
        # shared tokens so two tiny token sets sharing one word can't clear the
        # ratio. Both conditions must hold to count as coverage.
        def meaningful_overlap?(task_tokens, skill_tokens)
          shared = task_tokens & skill_tokens
          return false if shared.size < MIN_SHARED_SALIENT

          union = (task_tokens | skill_tokens).size
          union.positive? && (shared.size.to_f / union) >= COVERAGE_JACCARD
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
              parts << "TOOL #{m.tool_name if m.respond_to?(:tool_name)}: #{m.content.to_s[0, 400]}"
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
          content = "---\nname: #{name}\ndescription: #{yaml_scalar(desc)}\n---\n\n#{body}"
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

        # The agent HOME skills dir (RUBINO_HOME → else ~/.rubino), the SAME
        # place Installer writes and the Registry discovers via its
        # "~/.rubino/skills" entry. A distilled skill must land here, NOT in the
        # cwd, so a turn run inside a repo never leaks a SKILL.md into that
        # repo's working tree (SK-1). Mirrors Hermes (HERMES_HOME/skills).
        def skills_write_dir
          File.join(Config::Loader.default_home_path, "skills")
        end

        def registry
          @registry ||= Skills::Registry.new
        end
      end
    end
  end
end

# Register the handler
Rubino::Jobs::Registry.register(
  "DistillSkillJob", Rubino::Jobs::Handlers::DistillSkillJob
)
