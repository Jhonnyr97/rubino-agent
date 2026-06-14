# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "factory_bot", "~> 6.4"
  gem "parallel_tests", "~> 4.7"
  gem "rack-test", "~> 2.1"
  gem "rspec", "~> 3.12"
  gem "rubocop", "~> 1.60"
  gem "rubocop-rspec", "~> 3.0"
  gem "simplecov", "~> 0.22"
  gem "webmock", "~> 3.19"
end

group :development do
  # File watcher used by bin/dev to restart the fake-LLM server when
  # lib/ or scenario YAMLs change. Not loaded in test/CI.
  gem "rerun", "~> 0.14"
end
