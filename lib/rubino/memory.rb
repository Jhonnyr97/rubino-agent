# frozen_string_literal: true

require "sequel"

module Rubino
  # Helpers shared by the memory backends (the legacy Store and the FTS-backed
  # Sqlite backend), which don't share a class hierarchy. Pure module functions
  # parameterized by the backend's own dataset/column, so each backend keeps its
  # distinct schema (`:memories`/`:content` vs `:memory_facts`/`:text`) and its
  # own budget config while the id-resolution and the budget compare+raise live
  # in one place.
  module Memory
    module_function

    # Resolve a caller-supplied id to AT MOST ONE row of +dataset+. A blank id
    # resolves to nothing — a bare-prefix LIKE on "" matches the `%` wildcard
    # (EVERY row), so `memory delete ""` would wipe the whole store and report
    # success (#416). An EXACT id wins; a non-empty prefix is accepted ONLY when
    # unambiguous (matches exactly one row), so a short id from `memory list`
    # still resolves but a 1-char prefix can never mass-select. limit(2)
    # distinguishes "one" from "many".
    def resolve_row(dataset, id)
      key = id.to_s
      return nil if key.strip.empty?

      exact = dataset.where(id: key).first
      return exact if exact

      matches = dataset.where(Sequel.like(:id, "#{key}%")).limit(2).all
      matches.size == 1 ? matches.first : nil
    end

    # The group-split char-budget check, shared by store/replace/update across
    # backends: raise BudgetExceededError when adding +requested+ chars to a
    # group already holding +current+ would exceed +limit+. Callers compute
    # group/limit/current themselves (each backend meters a different
    # column/dataset and reads a different config key) and call this only after
    # confirming the limit is set, so a disabled budget never reaches here.
    def enforce_budget!(group:, limit:, current:, requested:)
      return if current + requested <= limit

      raise Store::BudgetExceededError.new(
        group: group, limit: limit, current: current, requested: requested
      )
    end
  end
end
