# frozen_string_literal: true

RSpec.describe Rubino::Memory::SalienceGate do
  # Exercised through a host class, the way the Sqlite backend includes it.
  let(:gate) { Class.new { include Rubino::Memory::SalienceGate }.new }

  def salient?(turn)
    gate.send(:salient?, turn)
  end

  describe "NOOP (non-salient) turns" do
    it "suppresses a bare greeting" do
      expect(salient?("USER: hi")).to be(false)
      expect(salient?("USER: hello there")).to be(false)
    end

    it "suppresses a one-word command reflex like 'help'" do
      expect(salient?("USER: help")).to be(false)
      expect(salient?("USER: commands")).to be(false)
      expect(salient?("USER: ?")).to be(false)
    end

    it "suppresses bare acknowledgements" do
      expect(salient?("USER: thanks")).to be(false)
      expect(salient?("USER: ok cool")).to be(false)
      expect(salient?("USER: yeah done")).to be(false)
    end

    it "suppresses a throwaway turn with no user-asserted durable info" do
      expect(salient?("USER: what now")).to be(false)
      expect(salient?("USER: go on")).to be(false)
    end

    it "suppresses an assistant-only turn (nothing the user asserted)" do
      expect(salient?("ASSISTANT: User decided to remove the mode feature.")).to be(false)
    end

    it "suppresses an empty / whitespace transcript" do
      expect(salient?("")).to be(false)
      expect(salient?("   \n  ")).to be(false)
    end
  end

  describe "salient turns (let the aux model decide)" do
    it "passes an explicit identity assertion" do
      expect(salient?("USER: my name is Mel")).to be(true)
    end

    it "passes a preference / deploy convention even when short" do
      expect(salient?("USER: I deploy with Kamal")).to be(true)
      expect(salient?("USER: I prefer tabs")).to be(true)
      expect(salient?("USER: I use zsh")).to be(true)
    end

    it "passes an explicit remember request" do
      expect(salient?("USER: remember that the API base url is example.com")).to be(true)
    end

    it "passes a substantive multi-word turn even without a first-person verb" do
      expect(salient?("USER: the project uses pytest with the xdist plugin")).to be(true)
    end

    it "gates on USER text, not assistant narration" do
      # Transient task-chatter leaks in via the assistant; the USER line here is
      # a bare ack, so the whole turn is a NOOP regardless of what the assistant
      # narrated.
      turn = "USER: ok\nASSISTANT: User decided to remove the mode feature and ran the suite."
      expect(salient?(turn)).to be(false)
    end
  end
end
