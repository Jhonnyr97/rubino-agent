# frozen_string_literal: true

module Strings
  # BUG: this is supposed to reverse the words in a sentence
  # ("hello world there" -> "there world hello") but it reverses
  # the characters instead.
  def self.reverse_words(sentence)
    sentence.reverse
  end
end
