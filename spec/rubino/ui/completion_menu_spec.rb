# frozen_string_literal: true

RSpec.describe Rubino::UI::CompletionMenu do
  subject(:menu) { described_class.new(source) }

  # A minimal CompletionSource double: every /command and @mention partial gets
  # a single candidate so we can assert purely on WHEN the menu arms (the token
  # detection under test), not on candidate discovery.
  let(:source) do
    Class.new do
      def candidates_for(token)
        case token[0]
        when "/" then ["#{token}status"]
        when "@" then ["#{token}file.rb"]
        else []
        end
      end
    end.new
  end

  # Drive the menu exactly as the composer does on each keystroke, with the
  # cursor at end of buffer, and report whether the menu armed + on what span.
  def arm(buffer)
    menu.auto_update(buffer, buffer.chars.length)
    return nil unless menu.open?

    menu.items
  end

  describe "slash command palette (first token only)" do
    it "arms for /help at the very start of the line" do
      expect(arm("/help")).to eq(["/helpstatus"])
    end

    it "arms for a bare / at the start of the line" do
      expect(arm("/")).to eq(["/status"])
    end

    it "arms after leading spaces at the very start of the line" do
      expect(arm("   /he")).to eq(["/hestatus"])
    end

    it "does NOT arm for a trailing / after 'ls ' (mid-line slash is literal)" do
      expect(arm("ls /")).to be_nil
    end

    it "does NOT arm for '/' after 'rm -rf ' — the dangerous repro" do
      expect(arm("rm -rf /")).to be_nil
    end

    it "does NOT arm for a /foo word mid-line" do
      expect(arm("cat /etc")).to be_nil
    end

    it "does NOT arm inside a URL like https://" do
      expect(arm("see https:/")).to be_nil
    end
  end

  describe "Enter on a mid-line slash does not corrupt the line" do
    # The whole point: with the menu closed, the composer never accept-splices,
    # so `rm -rf /` + Enter submits literally instead of becoming `rm -rf /status`.
    it "leaves the menu closed so the buffer is submitted verbatim" do
      arm("rm -rf /")

      expect(menu.open?).to be(false)
      # No splice is offered because there is no open state to accept.
      expect { menu.accept_splice }.to raise_error(NoMethodError)
    end
  end

  describe "@-mention picker (start OR after whitespace)" do
    it "arms for a bare @ at the start of the line" do
      expect(arm("@")).to eq(["@file.rb"])
    end

    it "arms for an @file after a space (mentions may appear mid-line)" do
      expect(arm("see @lib")).to eq(["@libfile.rb"])
    end

    it "arms for @foo at the very start" do
      expect(arm("@lib")).to eq(["@libfile.rb"])
    end
  end
end
