# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/strings"

class StringsTest < Minitest::Test
  def test_reverse_words
    assert_equal "there world hello", Strings.reverse_words("hello world there")
  end

  def test_single_word
    assert_equal "ruby", Strings.reverse_words("ruby")
  end
end
