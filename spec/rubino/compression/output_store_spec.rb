# frozen_string_literal: true

RSpec.describe Rubino::Compression::OutputStore do
  subject(:store) { described_class.new(capacity: 3) }

  it "round-trips stored text by its sha256 key" do
    key = store.put("hello world")
    expect(store.get(key)).to eq("hello world")
  end

  it "returns nil for an unknown key" do
    expect(store.get("deadbeef")).to be_nil
  end

  it "is content-addressed: identical text yields one entry, same key" do
    a = store.put("same")
    b = store.put("same")
    expect(a).to eq(b)
    expect(store.size).to eq(1)
  end

  it "evicts the least-recently-used entry past capacity" do
    k1 = store.put("one")
    store.put("two")
    store.put("three")
    store.put("four") # evicts "one" (LRU)
    expect(store.get(k1)).to be_nil
    expect(store.size).to eq(3)
  end

  it "a get refreshes LRU position so a touched entry survives eviction" do
    k1 = store.put("one")
    store.put("two")
    store.put("three")
    store.get(k1)      # touch "one" -> now MRU
    store.put("four")  # evicts "two" (now LRU), not "one"
    expect(store.get(k1)).to eq("one")
  end
end
