# frozen_string_literal: true

module APIRequestHelper
  def make_request(body: {}, params: {}, headers: {})
    env = {
      "rubino.json" => body,
      "QUERY_STRING" => ""
    }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    Rubino::API::Request.new(env, params.transform_keys(&:to_s))
  end

  def with_test_db
    db_connection = test_database
    allow(Rubino).to receive(:database).and_return(db_connection)
    db_connection.db
  end
end

RSpec.configure do |config|
  config.include APIRequestHelper
end
