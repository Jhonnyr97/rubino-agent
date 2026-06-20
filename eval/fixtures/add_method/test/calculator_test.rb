# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/calculator"

class CalculatorTest < Minitest::Test
  def test_add
    assert_equal 5, Calculator.new.add(2, 3)
  end

  def test_multiply
    assert_equal 12, Calculator.new.multiply(3, 4)
  end
end
