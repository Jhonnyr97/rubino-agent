# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe Rubino::UpdateCheck do
  # Hard isolation: every example resolves its cache under a throwaway tmpdir,
  # NEVER the developer's real ~/.rubino. The around block pins RUBINO_HOME to
  # the tmpdir and restores the prior value in an ensure (so a raising example
  # can't leave the env pointing at the tmpdir after it is deleted). Detached
  # refresh threads are joined before the around block tears the env down, so
  # no thread can survive long enough to write_cache into the real home — the
  # exact leak that once poisoned ~/.rubino/update_check.json with v99.0.0.
  around do |example|
    Dir.mktmpdir("rubino_update_check") do |dir|
      orig = ENV.fetch("RUBINO_HOME", nil)
      ENV["RUBINO_HOME"] = dir
      @home = dir
      begin
        example.run
      ensure
        (Thread.list - [Thread.current]).each { |t| t.join(2) if t[:rubino_update_refresh] }
        ENV["RUBINO_HOME"] = orig
      end
    end
  end

  def write_cache(latest:, checked_at: Time.now.utc.iso8601)
    File.write(
      File.join(@home, "update_check.json"),
      JSON.generate("checked_at" => checked_at, "latest" => latest)
    )
  end

  before { stub_const("Rubino::VERSION", "0.3.0") }

  describe ".notice_from_cache" do
    it "shows the dim notice when the cached latest is newer" do
      write_cache(latest: "0.4.1")
      expect(described_class.notice_from_cache)
        .to eq("▸ rubino v0.4.1 available — run `rubino update`")
    end

    it "hides the notice when the cached latest equals the running version" do
      write_cache(latest: "0.3.0")
      expect(described_class.notice_from_cache).to be_nil
    end

    it "hides the notice when the cached latest is older" do
      write_cache(latest: "0.2.9")
      expect(described_class.notice_from_cache).to be_nil
    end

    it "is silent (nil) when no cache file exists" do
      expect(described_class.notice_from_cache).to be_nil
    end

    it "no-ops on the unpublished 'unknown' sentinel" do
      write_cache(latest: "unknown")
      expect(described_class.notice_from_cache).to be_nil
    end

    it "no-ops on a non-semver garbage value" do
      write_cache(latest: "not-a-version")
      expect(described_class.notice_from_cache).to be_nil
    end

    it "no-ops on a nil latest" do
      write_cache(latest: nil)
      expect(described_class.notice_from_cache).to be_nil
    end

    it "no-ops on a corrupt cache file" do
      File.write(File.join(@home, "update_check.json"), "{not json")
      expect(described_class.notice_from_cache).to be_nil
    end

    # #phantom-version: a future-dated checked_at made the old stale? return a
    # negative age (never >= 24h), latching the poisoned cache so it re-rendered
    # forever. The notifier must self-heal: no phantom notice off a forward-dated
    # entry, even when its `latest` is a higher (but bogus) version.
    it "does not render the phantom notice when checked_at is in the future" do
      write_cache(latest: "99.0.0", checked_at: "2099-01-01T00:00:00Z")
      expect(described_class.notice_from_cache).to be_nil
    end

    it "does not render the phantom notice on a slightly-future checked_at (clock skew)" do
      write_cache(latest: "0.4.1", checked_at: (Time.now.utc + 3600).iso8601)
      expect(described_class.notice_from_cache).to be_nil
    end

    # #66: the documented opt-out is "no network, no notice, no thread" — a
    # previously-cached newer version must not leak the boot notice through.
    it "hides the notice when RUBINO_NO_UPDATE_CHECK is set, even with a newer cached version" do
      write_cache(latest: "0.4.1")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("RUBINO_NO_UPDATE_CHECK").and_return("1")

      expect(described_class.notice_from_cache).to be_nil
    end
  end

  describe ".newer? / .semver?" do
    it "treats a strictly-greater semver as newer" do
      expect(described_class.newer?("0.3.1")).to be(true)
      expect(described_class.newer?("1.0.0")).to be(true)
    end

    it "treats equal or older as not newer" do
      expect(described_class.newer?("0.3.0")).to be(false)
      expect(described_class.newer?("0.2.0")).to be(false)
    end

    it "rejects unknown/nil/garbage" do
      expect(described_class.semver?("unknown")).to be(false)
      expect(described_class.semver?(nil)).to be(false)
      expect(described_class.semver?("v1.2.3")).to be(false)
      expect(described_class.newer?("unknown")).to be(false)
      expect(described_class.newer?(nil)).to be(false)
    end

    it "accepts pre-release semver" do
      expect(described_class.semver?("0.4.0.beta1")).to be(true)
    end
  end

  describe ".fetch_latest" do
    it "returns nil on the 'unknown' sentinel (unpublished gem)" do
      stub_http_body('{"version":"unknown"}')
      expect(described_class.fetch_latest).to be_nil
    end

    it "returns the version string for a real publish" do
      stub_http_body('{"version":"0.4.1"}')
      expect(described_class.fetch_latest).to eq("0.4.1")
    end

    it "returns nil on any network error" do
      allow(Net::HTTP).to receive(:new).and_raise(SocketError)
      expect(described_class.fetch_latest).to be_nil
    end

    def stub_http_body(body)
      res = instance_double(Net::HTTPOK, body: body)
      allow(res).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(res)
      allow(Net::HTTP).to receive(:new).and_return(http)
    end
  end

  describe ".refresh_async_if_stale" do
    before do
      allow($stdout).to receive(:tty?).and_return(true)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CI").and_return(nil)
      allow(ENV).to receive(:[]).with("RUBINO_NO_UPDATE_CHECK").and_return(nil)
    end

    it "is disabled by the opt-out env (no thread, no network)" do
      allow(ENV).to receive(:[]).with("RUBINO_NO_UPDATE_CHECK").and_return("1")
      expect(described_class).not_to receive(:fetch_latest)
      expect(described_class.refresh_async_if_stale).to be_nil
    end

    it "is disabled when not a TTY" do
      allow($stdout).to receive(:tty?).and_return(false)
      expect(described_class.refresh_async_if_stale).to be_nil
    end

    it "is disabled under CI" do
      allow(ENV).to receive(:[]).with("CI").and_return("true")
      expect(described_class.refresh_async_if_stale).to be_nil
    end

    it "is gated once/24h: skips when the cache was checked <24h ago" do
      write_cache(latest: "0.3.0", checked_at: (Time.now.utc - 3600).iso8601)
      expect(described_class.refresh_async_if_stale).to be_nil
    end

    it "refreshes when the cache is stale (>24h) and never blocks boot" do
      write_cache(latest: "0.3.0", checked_at: (Time.now.utc - (25 * 3600)).iso8601)
      allow(described_class).to receive(:fetch_latest).and_return("0.5.0")
      thread = described_class.refresh_async_if_stale
      expect(thread).to be_a(Thread)
      thread.join # tests await it explicitly; the boot path never does
      expect(described_class.cached_latest).to eq("0.5.0")
    end

    it "refreshes when no cache exists yet" do
      allow(described_class).to receive(:fetch_latest).and_return("0.6.0")
      described_class.refresh_async_if_stale.join
      expect(described_class.cached_latest).to eq("0.6.0")
    end

    # Self-heal: a future-dated cache (negative age) must be treated as STALE so
    # the poisoned entry is overwritten by a real check instead of latched.
    it "re-checks (treats as stale) when checked_at is in the future and overwrites the poison" do
      write_cache(latest: "99.0.0", checked_at: "2099-01-01T00:00:00Z")
      expect(described_class).to be_stale
      allow(described_class).to receive(:fetch_latest).and_return("0.4.0")
      described_class.refresh_async_if_stale.join
      expect(described_class.cached_latest).to eq("0.4.0")
    end

    it "leaves the cache untouched and stays silent on a failed fetch" do
      write_cache(latest: "0.3.0", checked_at: (Time.now.utc - (25 * 3600)).iso8601)
      allow(described_class).to receive(:fetch_latest).and_return(nil)
      described_class.refresh_async_if_stale.join
      expect(described_class.cached_latest).to eq("0.3.0")
    end
  end

  describe ".install_method / .gem_update_command" do
    it "reports :gem when a matching spec is installed" do
      allow(described_class).to receive(:installed_gem_version).with("rubino-agent").and_return("0.3.0")
      expect(described_class.install_method).to eq(:gem)
    end

    it "reports :source when no spec is installed" do
      allow(described_class).to receive(:installed_gem_version).with("rubino-agent").and_return(nil)
      expect(described_class.install_method).to eq(:source)
    end

    it "builds the argv with the active interpreter (no shell)" do
      expect(described_class.gem_update_command)
        .to eq([Gem.ruby, "-S", "gem", "update", "rubino-agent"])
    end
  end

  describe ".clear_cache!" do
    it "removes the cache file" do
      write_cache(latest: "0.4.1")
      described_class.clear_cache!
      expect(File.exist?(File.join(@home, "update_check.json"))).to be(false)
    end
  end

  # Guardrail against the test-isolation leak that poisoned the developer's real
  # ~/.rubino: every write must land under the throwaway @home, never $HOME.
  describe "test isolation" do
    it "resolves the cache under the isolated tmp home, not the real ~/.rubino" do
      expect(described_class.cache_path).to start_with(@home)
      expect(described_class.cache_path)
        .not_to eq(File.expand_path("~/.rubino/update_check.json"))
    end

    it "writes the refreshed cache into the tmp home only" do
      allow($stdout).to receive(:tty?).and_return(true)
      allow(described_class).to receive(:fetch_latest).and_return("0.4.0")
      described_class.refresh_async_if_stale.join
      expect(File.exist?(File.join(@home, "update_check.json"))).to be(true)
    end
  end
end
