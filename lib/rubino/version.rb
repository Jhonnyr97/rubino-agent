# frozen_string_literal: true

module Rubino
  VERSION = "0.5.3"

  # The ONE product tagline (#559). Both chrome surfaces that introduce rubino —
  # the `rubino --help` banner (CLI::Commands::TAGLINE) and the first-run chat
  # welcome (Commands::Executor#show_welcome) — render this single string, so the
  # two no longer drift into two different one-liners.
  TAGLINE = "rubino — an AI coding agent that reads, edits, and runs code."
end
