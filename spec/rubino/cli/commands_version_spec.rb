# frozen_string_literal: true

# #32: `rubino --version` / `-v` must print the version and exit at dispatch,
# BEFORE the args are treated as a chat prompt (which otherwise fails with an
# API-key error). Handled in Commands.start so it works on a fresh home.
RSpec.describe Rubino::CLI::Commands, "--version dispatch" do
  it "prints the version for --version and never invokes the chat task" do
    # The interceptor returns before delegating to Thor's dispatch (super), so
    # a fresh home never hits the chat/credential path.
    expect(described_class).not_to receive(:dispatch)
    expect { described_class.start(["--version"]) }
      .to output(/#{Regexp.escape(Rubino::VERSION)}/).to_stdout
  end

  it "prints the version for -v" do
    expect { described_class.start(["-v"]) }
      .to output(/#{Regexp.escape(Rubino::VERSION)}/).to_stdout
  end

  it "does not intercept --version when it is not the first arg (stays a normal arg)" do
    # Only a leading --version is the global flag; otherwise Thor handles args
    # as usual. We assert the interceptor short-circuit does NOT fire here.
    allow(described_class).to receive(:dispatch) # swallow real dispatch
    out = capture_stdout { described_class.start(["chat", "--version"]) }
    expect(out).not_to match(/\A#{Regexp.escape("rubino v#{Rubino::VERSION}")}/)
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end
