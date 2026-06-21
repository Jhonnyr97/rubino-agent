# frozen_string_literal: true

# A deliberately CHATTY inventory module: many methods with non-trivial bodies
# so a whole-file read is worth skeletonising (> 150 lines), and one BUG the
# agent must fix. The test suite is verbose so a `run the tests` shell call
# produces a long log the seam can compress.
module Inventory
  # An item on a shelf: sku, name, quantity, unit price in cents.
  class Item
    attr_reader :sku, :name, :quantity, :unit_price_cents

    def initialize(sku:, name:, quantity:, unit_price_cents:)
      @sku = sku
      @name = name
      @quantity = quantity
      @unit_price_cents = unit_price_cents
    end

    def total_value_cents
      quantity * unit_price_cents
    end

    def restock(amount)
      raise ArgumentError, "amount must be positive" unless amount.positive?

      @quantity += amount
      self
    end

    def sell(amount)
      raise ArgumentError, "amount must be positive" unless amount.positive?
      raise "insufficient stock for #{sku}" if amount > quantity

      @quantity -= amount
      self
    end

    def low_stock?(threshold = 5)
      quantity <= threshold
    end

    def to_h
      { sku: sku, name: name, quantity: quantity, unit_price_cents: unit_price_cents }
    end
  end

  # A warehouse holds many items keyed by sku and answers aggregate questions.
  class Warehouse
    def initialize
      @items = {}
    end

    def add(item)
      raise "duplicate sku #{item.sku}" if @items.key?(item.sku)

      @items[item.sku] = item
      self
    end

    def fetch(sku)
      @items.fetch(sku) { raise "unknown sku #{sku}" }
    end

    def each(&block)
      @items.values.each(&block)
    end

    def total_items
      @items.size
    end

    def total_units
      @items.values.sum(&:quantity)
    end

    # BUG: total_value_cents sums the QUANTITY instead of each item's total
    # value (quantity * unit price). The test expects the monetary total.
    def total_value_cents
      @items.values.sum(&:quantity)
    end

    def low_stock(threshold = 5)
      @items.values.select { |i| i.low_stock?(threshold) }
    end

    def restock(sku, amount)
      fetch(sku).restock(amount)
    end

    def sell(sku, amount)
      fetch(sku).sell(amount)
    end

    def skus
      @items.keys.sort
    end

    def to_a
      @items.values.map(&:to_h)
    end
  end

  # A small reporting helper over a warehouse.
  module Report
    module_function

    def summary(warehouse)
      lines = []
      lines << "items: #{warehouse.total_items}"
      lines << "units: #{warehouse.total_units}"
      lines << "value_cents: #{warehouse.total_value_cents}"
      lines.join("\n")
    end

    def low_stock_skus(warehouse, threshold = 5)
      warehouse.low_stock(threshold).map(&:sku).sort
    end

    def most_valuable(warehouse)
      warehouse.each.max_by(&:total_value_cents)
    end

    def average_unit_price_cents(warehouse)
      items = warehouse.to_a
      return 0 if items.empty?

      items.sum { |h| h[:unit_price_cents] } / items.length
    end
  end
end
