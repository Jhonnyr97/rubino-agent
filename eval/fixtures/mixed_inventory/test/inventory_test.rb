# frozen_string_literal: true

require "minitest/autorun"
require "inventory"

# Verbose on purpose: many passing assertions so a `ruby -Itest -Ilib test/...`
# run prints a long progress log (the noise the log compressor drops), plus the
# one failing case the agent's fix must turn green.
class InventoryTest < Minitest::Test
  def setup
    @w = Inventory::Warehouse.new
    @w.add(Inventory::Item.new(sku: "A1", name: "Widget", quantity: 10, unit_price_cents: 250))
    @w.add(Inventory::Item.new(sku: "B2", name: "Gadget", quantity: 3, unit_price_cents: 1000))
    @w.add(Inventory::Item.new(sku: "C3", name: "Gizmo", quantity: 50, unit_price_cents: 75))
  end

  def test_total_items
    assert_equal 3, @w.total_items
  end

  def test_total_units
    assert_equal 63, @w.total_units
  end

  def test_item_total_value
    assert_equal 2500, @w.fetch("A1").total_value_cents
  end

  def test_low_stock
    assert_equal ["B2"], @w.low_stock.map(&:sku)
  end

  def test_restock
    @w.restock("B2", 5)
    assert_equal 8, @w.fetch("B2").quantity
  end

  def test_sell
    @w.sell("C3", 10)
    assert_equal 40, @w.fetch("C3").quantity
  end

  def test_skus_sorted
    assert_equal %w[A1 B2 C3], @w.skus
  end

  def test_report_summary_has_items_line
    assert_includes Inventory::Report.summary(@w), "items: 3"
  end

  def test_most_valuable
    assert_equal "C3", Inventory::Report.most_valuable(@w).sku
  end

  def test_average_unit_price
    assert_equal 441, Inventory::Report.average_unit_price_cents(@w)
  end

  # The failing test: warehouse value must be the sum of each item's
  # quantity * unit_price, not the unit count.
  def test_total_value_cents_is_monetary
    expected = (10 * 250) + (3 * 1000) + (50 * 75)
    assert_equal expected, @w.total_value_cents
  end
end
