# frozen_string_literal: true

# #369b — a one-shot (`rubino -q` / `prompt`) run that distils a skill must tell
# the user. SKILL_CREATED is emitted (inline skill(create) AND the post-turn
# distill job) on the process-global bus, but the headless Null UI swallows it,
# so the user never learns a skill was produced. The one-shot path now collects
# those names and surfaces a concise "distilled new skill: <name>" line to
# STDERR — off the clean stdout answer (the #372 routing discipline).
RSpec.describe Rubino::CLI::ChatCommand do
  let(:cmd) { described_class.new }

  before do
    # Fresh global bus so a prior spec's listeners can't fire here.
    Rubino.event_bus.clear!
  end

  def capture_stderr
    orig = $stderr
    buf = StringIO.new
    $stderr = buf
    yield
    buf.string
  ensure
    $stderr = orig
  end

  it "collects SKILL_CREATED names emitted on the global bus during the turn" do
    names = cmd.send(:subscribe_created_skills)

    Rubino.event_bus.emit(Rubino::Interaction::Events::SKILL_CREATED,
                          name: "data-pipeline", file_path: "/x/SKILL.md")

    expect(names).to eq(["data-pipeline"])
  end

  it "surfaces a 'distilled new skill' notice to STDERR, not stdout" do
    names = cmd.send(:subscribe_created_skills)
    Rubino.event_bus.emit(Rubino::Interaction::Events::SKILL_CREATED,
                          name: "data-pipeline", file_path: "/x/SKILL.md")

    err = capture_stderr { cmd.send(:announce_created_skills, names) }

    expect(err).to include("distilled new skill: data-pipeline")
  end

  it "emits nothing when no skill was created" do
    err = capture_stderr { cmd.send(:announce_created_skills, []) }
    expect(err).to eq("")
  end

  it "dedups a name created both inline and by the distill job" do
    names = cmd.send(:subscribe_created_skills)
    2.times do
      Rubino.event_bus.emit(Rubino::Interaction::Events::SKILL_CREATED,
                            name: "dupe", file_path: "/x/SKILL.md")
    end

    err = capture_stderr { cmd.send(:announce_created_skills, names) }

    expect(err.scan(/distilled new skill: dupe/).size).to eq(1)
  end
end
