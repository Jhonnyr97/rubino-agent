# frozen_string_literal: true

require "rack/test"
require "json"

# Rack::Test harness for HTTP-boundary contract specs.
#
# Spins up the full middleware stack via API::Server.build_app (Observability +
# ErrorHandler + JsonParser + Auth + Router) with a per-spec router so each
# group wires only the routes it exercises. The DB is the in-memory test one
# from with_test_db, and the API key is fixed so auth assertions stay stable.
module APIContractHelper
  include Rack::Test::Methods

  API_KEY = "contract-test-key"

  def app
    @app ||= Rubino::API::Server.build_app(
      router: contract_router,
      api_key: API_KEY,
      logger: contract_logger
    )
  end

  # Captured logger lines so test failures can show the masked 500's underlying cause.
  def contract_log_io
    @contract_log_io ||= StringIO.new
  end

  def contract_logger
    @contract_logger ||= Rubino::Logger.new(io: contract_log_io, level: :error)
  end

  # Override in each spec group to wire only the routes under test.
  def contract_router
    raise NotImplementedError, "spec must define #contract_router"
  end

  def auth_headers
    { "HTTP_AUTHORIZATION" => "Bearer #{API_KEY}" }
  end

  def post_json(path, payload, headers: {})
    post(path, JSON.generate(payload), { "CONTENT_TYPE" => "application/json" }.merge(auth_headers).merge(headers))
  end

  def patch_json(path, payload, headers: {})
    patch(path, JSON.generate(payload), { "CONTENT_TYPE" => "application/json" }.merge(auth_headers).merge(headers))
  end

  def get_json(path, headers: {})
    get(path, {}, auth_headers.merge(headers))
  end

  def delete_json(path, headers: {})
    delete(path, {}, auth_headers.merge(headers))
  end

  def json_body
    JSON.parse(last_response.body)
  end
end

RSpec.configure do |config|
  config.include APIContractHelper, type: :contract
  config.define_derived_metadata(file_path: %r{/spec/rubino/api/contract/}) do |meta|
    meta[:type] = :contract
  end
end
