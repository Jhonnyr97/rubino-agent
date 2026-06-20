# frozen_string_literal: true

require "yaml"
require "fileutils"
require "tmpdir"

module Eval
  # Builds an ISOLATED, throwaway environment for one rubino run:
  #
  #   * a temp RUBINO_HOME holding a config.yml derived from the user's real
  #     config (so the model/provider/api-key actually resolve) but with the
  #     A/B TOGGLE key forced to a given value. The user's own
  #     ~/.rubino/config.yml is NEVER mutated.
  #   * the user's ~/.rubino/.env copied in, so ${MINIMAX_API_KEY} (and any
  #     other secret the config interpolates) still resolves.
  #   * a fresh copy of the task fixture as the working directory, so edit
  #     tasks can change files without touching the repo's tracked fixtures or
  #     each other.
  #
  # Everything lives under one temp root that #cleanup removes.
  class Workspace
    attr_reader :root, :home, :workdir

    # source_home — the real rubino home to clone config/.env from.
    # fixtures_dir — eval/fixtures.
    def initialize(source_home:, fixtures_dir:)
      @source_home  = source_home
      @fixtures_dir = fixtures_dir
      @root    = Dir.mktmpdir("rubino-eval-")
      @home    = File.join(@root, "home")
      @workdir = File.join(@root, "work")
      FileUtils.mkdir_p([@home, @workdir])
    end

    # Writes the isolated config.yml: the user's config deep-overridden with the
    # toggle key set to `value`. flag_path is a dotted key, e.g.
    # "compression.enabled" or "display.runtime_footer.enabled". When value is
    # nil the key is left untouched (the OFF arm for a flag that defaults off).
    def prepare_config!(flag_path:, value:)
      config = base_config
      set_dotted!(config, flag_path, value) unless value.nil?
      File.write(File.join(@home, "config.yml"), YAML.dump(config))
      copy_env!
      self
    end

    # Copies the fixture dir (if any) into the working directory.
    def stage_fixture!(fixture)
      return self if fixture.nil? || fixture.to_s.empty?

      src = File.join(@fixtures_dir, fixture)
      raise "fixture not found: #{src}" unless Dir.exist?(src)

      FileUtils.cp_r(File.join(src, "."), @workdir)
      self
    end

    def cleanup
      FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
    rescue StandardError
      # best-effort; a temp dir left behind is harmless
    end

    private

    # The user's real config as a Hash, or a minimal default if none exists.
    def base_config
      path = File.join(@source_home, "config.yml")
      return {} unless File.exist?(path)

      YAML.safe_load_file(path, permitted_classes: [Symbol]) || {}
    end

    def copy_env!
      env = File.join(@source_home, ".env")
      FileUtils.cp(env, File.join(@home, ".env")) if File.exist?(env)
    end

    # Sets a dotted key path in a nested hash, creating intermediate hashes.
    # set_dotted!(h, "a.b.c", true) => h["a"]["b"]["c"] = true.
    def set_dotted!(hash, dotted, value)
      keys = dotted.split(".")
      leaf = keys[0..-2].reduce(hash) do |node, k|
        node[k] = {} unless node[k].is_a?(Hash)
        node[k]
      end
      leaf[keys.last] = value
    end
  end
end
