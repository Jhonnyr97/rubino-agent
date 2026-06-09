# frozen_string_literal: true

# Graph-lite layer for Memory::Backends::Sqlite (Memory Phase 3b).
#
# Layers a tiny entity/relationship graph on top of the atomic-fact store so
# RELATIONAL queries ("what does X use for Y") surface facts connected via a
# 1-hop edge that pure FTS on the probe would miss. This is deliberately NOT a
# graph DB: two ordinary tables + bounded/recursive SQL.
#
#   memory_entities  — resolved nodes (people, tools, projects). `name_norm` is
#                      the lowercased key used for resolution/lookup so the same
#                      entity from different facts collapses to one node.
#   memory_edges     — typed relationships between two entities, each carrying
#                      the `source_fact_id` it was derived from and bi-temporal
#                      validity (`valid_from`/`valid_to`) exactly like facts:
#                      a contradicted relation is soft-retired, not deleted.
#
# An edge is "live" when `valid_to IS NULL`, matching the fact convention.
Sequel.migration do
  up do
    create_table?(:memory_entities) do
      String :id, primary_key: true
      String :name, null: false # display form, first-seen casing
      String :name_norm, null: false # lowercased resolution key
      String :kind                       # person | tool | project | ... (best-effort)
      String :created_at, null: false
      String :updated_at, null: false

      index :name_norm, unique: true
    end

    create_table?(:memory_edges) do
      String :id, primary_key: true
      String :src_entity_id, null: false
      String :dst_entity_id, null: false
      String :relation, null: false      # lowercased relation label (uses, deploys_to, ...)
      String :source_fact_id             # the fact this edge was derived from
      String :valid_from
      String :valid_to                   # set when superseded; live edge = NULL
      String :superseded_by              # id of the edge that invalidated this one
      String :created_at, null: false
      String :updated_at, null: false

      index :src_entity_id
      index :dst_entity_id
      index :valid_to
      index %i[src_entity_id dst_entity_id relation]
    end
  end

  down do
    drop_table?(:memory_edges)
    drop_table?(:memory_entities)
  end
end
