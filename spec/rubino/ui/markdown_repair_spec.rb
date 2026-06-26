# frozen_string_literal: true

RSpec.describe Rubino::UI::MarkdownRepair do
  def repair(text, fence: nil)
    described_class.close_open_spans(text, fence: fence)
  end

  describe "code fences" do
    it "closes an open plain code fence so the body renders as code" do
      tail = "```ruby\ndef hi"
      out = repair(tail, fence: { len: 3, plain: true })
      expect(out).to eq("```ruby\ndef hi\n```")
    end

    it "matches the opening backtick run length when closing" do
      tail = "````\nnested ``` inside"
      out = repair(tail, fence: { len: 4, plain: true })
      expect(out).to eq("````\nnested ``` inside\n````")
    end

    it "leaves a ```markdown/md WRAPPER untouched (renderer unwraps it)" do
      tail = "```markdown\n# Heading\n- item"
      expect(repair(tail, fence: { len: 3, plain: false })).to eq(tail)
    end

    it "never repairs emphasis INSIDE an open code fence" do
      tail = "```\nx = 2 ** 3  # **not bold"
      out = repair(tail, fence: { len: 3, plain: true })
      expect(out).to eq("```\nx = 2 ** 3  # **not bold\n```")
    end
  end

  describe "inline emphasis (outside code)" do
    it "closes a dangling **bold**" do
      expect(repair("Here is the **plan")).to eq("Here is the **plan**")
    end

    it "closes a dangling *italic*" do
      expect(repair("an *important")).to eq("an *important*")
    end

    it "closes a dangling _italic_" do
      expect(repair("an _important")).to eq("an _important_")
    end

    it "leaves already-balanced emphasis untouched" do
      expect(repair("Here is the **plan** now")).to eq("Here is the **plan** now")
    end

    it "closes the innermost span first when nested" do
      # Closes the inner * then the outer ** → "...italic*" + "**" = a trailing
      # *** that CommonMark balances as strong[bold and emph[italic]].
      expect(repair("**bold and *italic")).to eq("**bold and *italic***")
    end
  end

  describe "literal markers that do NOT open a span (no false repair)" do
    it "leaves a multiplication '2 * 3' untouched (space follows the *)" do
      expect(repair("the product 2 * 3 = 6")).to eq("the product 2 * 3 = 6")
    end

    it "leaves a trailing marker with whitespace after it untouched" do
      expect(repair("a bullet point * ")).to eq("a bullet point * ")
    end

    it "leaves snake_case identifiers untouched" do
      expect(repair("call user_id and order_id")).to eq("call user_id and order_id")
    end
  end

  describe "inline code spans" do
    it "closes a dangling single-backtick code span" do
      expect(repair("run `bundle exec")).to eq("run `bundle exec`")
    end

    it "leaves a balanced code span untouched" do
      expect(repair("run `bundle` now")).to eq("run `bundle` now")
    end

    it "does not treat emphasis inside an inline code span as open" do
      # The ** is inside `...` so it is literal; nothing to repair.
      expect(repair("the `a ** b` operator")).to eq("the `a ** b` operator")
    end
  end

  describe "edge cases" do
    it "returns nil/empty input unchanged" do
      expect(repair(nil)).to be_nil
      expect(repair("")).to eq("")
    end

    it "leaves plain prose untouched" do
      expect(repair("just some normal text.")).to eq("just some normal text.")
    end

    it "leaves headings and list prefixes untouched (no inline spans)" do
      expect(repair("# Title\n- one\n- two")).to eq("# Title\n- one\n- two")
    end
  end
end
