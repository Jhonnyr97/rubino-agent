# frozen_string_literal: true

# Graph-lite layer (Memory Phase 3b): entity nodes, co-occurrence edges (laid
# down on the write path from each fact's entity tags) with temporal
# supersession, and the 1-hop traversal blended into retrieval.
#
# NB: typed edges used to be emitted by the aux extractor's edges[]; with the
# structured extractor removed, only co-occurrence edges (from store entities)
# and edges written directly via #upsert_edge exist. Recall degrades gracefully
# — FTS still works; there are simply no extractor-authored typed edges.
RSpec.describe Rubino::Memory::SqliteGraph do
  let(:db_connection) { test_database }
  let(:db) { db_connection.db }
  let(:config) { test_configuration("memory" => memory_cfg) }
  let(:backend) { Rubino::Memory::Backends::Sqlite.new(config: config, db: db) }

  def memory_cfg(overrides = {})
    {
      "enabled" => true, "backend" => "sqlite",
      "user_profile_enabled" => true, "project_context_enabled" => true,
      "memory_char_limit" => 4000, "user_char_limit" => 1375,
      "sqlite" => { "vector" => false }
    }.merge(overrides)
  end

  describe "node resolution + co-occurrence edges on store" do
    it "upserts one node per distinct entity name (case-insensitive)" do
      backend.store(kind: "project", content: "Project uses pytest.", metadata: { entities: %w[project pytest] })
      backend.store(kind: "fact", content: "Pytest runs fast.", metadata: { entities: %w[Pytest speed] })
      names = db[:memory_entities].select_map(:name_norm).sort
      expect(names).to eq(%w[project pytest speed])
    end

    it "creates a co_occurs edge between every entity pair on a fact" do
      backend.store(kind: "project", content: "Project uses pytest with xdist.",
                    metadata: { entities: %w[project pytest xdist] })
      live = db[:memory_edges].where(valid_to: nil)
      expect(live.where(relation: "co_occurs").count).to eq(3) # C(3,2)
    end

    it "is idempotent — re-storing the same pair does not duplicate the edge" do
      2.times { |i| backend.store(kind: "fact", content: "fact #{i}", metadata: { entities: %w[a b] }) }
      expect(db[:memory_edges].where(relation: "co_occurs", valid_to: nil).count).to eq(1)
    end
  end

  describe "typed edges via #upsert_edge + supersession" do
    it "soft-retires a changed relation between the SAME entity pair" do
      app = backend.resolve_entity("app")
      redis = backend.resolve_entity("redis")
      backend.upsert_edge(app, redis, "considers", nil)
      # a later assertion changes the relation for the same app->redis pair
      # (the retire-then-insert sequence #index_fact_graph runs for typed edges)
      backend.supersede_edge(app, redis, "uses")
      backend.upsert_edge(app, redis, "uses", nil)

      retired = db[:memory_edges].where(src_entity_id: app, dst_entity_id: redis).exclude(valid_to: nil)
      live = db[:memory_edges].where(src_entity_id: app, dst_entity_id: redis, valid_to: nil)
      expect(retired.select_map(:relation)).to eq(%w[considers]) # old relation retired
      expect(live.select_map(:relation)).to eq(%w[uses])         # new relation live
    end
  end

  describe "#graph_neighbors — bounded 1-hop traversal" do
    before do
      # "app" --uses--> "redis"; query mentions only "app", must reach redis fact.
      backend.store(kind: "project", content: "The app is a Rails service.", metadata: { entities: %w[app rails] })
      @redis_fact = backend.store(kind: "fact", content: "Redis stores the cache.",
                                  metadata: { entities: %w[redis cache] })
      app = backend.resolve_entity("app")
      redis = backend.resolve_entity("redis")
      backend.upsert_edge(app, redis, "uses", nil)
    end

    it "returns facts reachable from a seed entity via a 1-hop edge" do
      ids = backend.graph_neighbors("what does the app use", 10)
      expect(ids).to include(@redis_fact[:id])
    end

    it "returns [] when the query mentions no known entity" do
      expect(backend.graph_neighbors("unrelated weather forecast", 10)).to eq([])
    end
  end

  describe "graph signal fused into retrieve ranking" do
    before do
      # FACT-1 ties query 'app' to entity app; FACT-2 (redis) is connected only
      # by a 1-hop 'uses' edge and shares NO keyword with the probe.
      backend.store(kind: "project", content: "The app deploys to Fly.", metadata: { entities: %w[app fly] })
      backend.store(kind: "fact", content: "Sidekiq processes background work.",
                    metadata: { entities: %w[redis sidekiq] })
      app = backend.resolve_entity("app")
      redis = backend.resolve_entity("redis")
      backend.upsert_edge(app, redis, "uses", nil)
    end

    it "surfaces a 1-hop-connected fact that pure FTS on the probe would miss" do
      # 'app' matches FACT-1 by FTS; the redis/sidekiq fact has no 'app' token,
      # so only the graph blend can pull it in.
      out = backend.retrieve(session_id: "s1", query: "app")
      texts = out.map { |r| r[:content] }
      expect(texts).to include("Sidekiq processes background work.")
    end

    it "the graph hop itself excludes facts not reachable from the seed" do
      coffee = backend.store(kind: "fact", content: "Unrelated note about coffee.", metadata: { entities: %w[coffee] })
      # coffee shares no entity and no edge with the 'app' seed: graph_neighbors
      # must not include it (recency may still surface it elsewhere).
      ids = backend.graph_neighbors("app", 10)
      expect(ids).not_to include(coffee[:id])
    end
  end
end
