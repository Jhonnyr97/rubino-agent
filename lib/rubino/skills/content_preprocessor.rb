# frozen_string_literal: true

module Rubino
  module Skills
    # Shared SKILL.md content preprocessing helpers, mirroring Hermes's
    # agent/skill_preprocessing.py. Applies template-variable substitution
    # and inline-shell expansion to skill content before it is injected
    # into the prompt (via /skill-name activation or the skill(load) tool).
    module ContentPreprocessor
      # Matches ${RUBINO_SKILL_DIR} / ${RUBINO_SESSION_ID} tokens in SKILL.md.
      # Unresolved tokens are left as-is so the author can spot them.
      SKILL_TEMPLATE_RE = /\$\{(RUBINO_SKILL_DIR|RUBINO_SESSION_ID)\}/

      # Matches inline shell snippets:  !`cmd`
      # Non-greedy, single-line only — no newlines inside the backticks.
      INLINE_SHELL_RE = /!`([^`\n]+)`/

      # Cap inline-shell output so a runaway command can't blow out the context.
      INLINE_SHELL_MAX_OUTPUT = 4000

      module_function

      # Apply configured preprocessing: template-variable substitution (on by
      # default) and inline-shell expansion (off by default). Mirrors Hermes's
      # `preprocess_skill_content`.
      def preprocess(content, skill_dir: nil, session_id: nil, config: nil)
        return content if content.nil? || content.empty?

        cfg = config || load_skills_config
        subs_enabled = cfg.fetch("template_vars", true)
        shell_enabled = cfg.fetch("inline_shell", false)

        content = substitute_template_vars(content, skill_dir: skill_dir, session_id: session_id) if subs_enabled
        if shell_enabled
          content = expand_inline_shell(
            content,
            skill_dir: skill_dir,
            timeout: cfg.fetch("inline_shell_timeout", 10).to_i
          )
        end
        content
      end

      # Replace ${RUBINO_SKILL_DIR} / ${RUBINO_SESSION_ID} in skill content.
      # Only substitutes tokens for which a concrete value is available —
      # unresolved tokens stay in place.
      def substitute_template_vars(content, skill_dir: nil, session_id: nil)
        return content if content.nil? || content.empty?

        content.gsub(SKILL_TEMPLATE_RE) do |match|
          token = Regexp.last_match(1)
          case token
          when "RUBINO_SKILL_DIR"
            skill_dir ? skill_dir.to_s : match
          when "RUBINO_SESSION_ID"
            session_id ? session_id.to_s : match
          else
            match
          end
        end
      end

      # Replace every `!`cmd`` snippet in content with its stdout.
      # Runs each snippet with the skill directory as CWD (for relative paths).
      def expand_inline_shell(content, skill_dir: nil, timeout: 10)
        return content unless content.include?("!`")

        content.gsub(INLINE_SHELL_RE) do
          cmd = Regexp.last_match(1).strip
          next "" if cmd.empty?

          run_inline_shell(cmd, skill_dir, timeout)
        end
      end

      # Execute a single inline-shell snippet and return its stdout (trimmed).
      # Failures return a short ``[inline-shell error: ...]`` marker instead of
      # raising, so one bad snippet can't wreck the whole skill message.
      def run_inline_shell(command, skill_dir, timeout)
        require "open3"

        cwd = skill_dir ? skill_dir.to_s : Dir.pwd
        out = nil
        Open3.popen3("bash", "-c", command, chdir: cwd) do |_stdin, stdout, stderr, wait_thr|
          out_reader = Thread.new { stdout.read }
          err_reader = Thread.new { stderr.read }
          unless wait_thr.join(timeout)
            Thread.kill(out_reader)
            Thread.kill(err_reader)
            begin
              Process.kill("TERM", wait_thr.pid)
            rescue Errno::ESRCH
              nil
            end
            return "[inline-shell timeout after #{timeout}s: #{command}]"
          end
          out_str = out_reader.value.to_s
          err_str = err_reader.value.to_s
          out = out_str unless out_str.empty?
          out ||= err_str unless err_str.empty?
          out ||= ""
        end

        output = out.rstrip
        output = "#{output[0...INLINE_SHELL_MAX_OUTPUT]}...[truncated]" if output.length > INLINE_SHELL_MAX_OUTPUT
        output
      rescue StandardError => e
        "[inline-shell error: #{e.message}]"
      end

      # Load the `skills` section of config (best-effort).
      def load_skills_config
        cfg = Rubino.configuration
        skills_cfg = cfg.is_a?(Hash) ? cfg.fetch("skills", {}) : {}
        skills_cfg.is_a?(Hash) ? skills_cfg : {}
      rescue StandardError
        {}
      end
    end
  end
end
