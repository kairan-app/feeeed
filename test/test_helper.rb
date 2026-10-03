ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "mocha/minitest"
require "minitest/rails"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    # fixtures :all

    # Add more helper methods to be used by all tests here...
    include FactoryBot::Syntax::Methods
  end
end

class ActionDispatch::IntegrationTest
  def sign_in(user)
    get "/dev/login", params: { user_id: user.id }
  end
end

# fetcher (Rust) 向け API のテスト用
module FetcherApiTestHelper
  def with_fetcher_tokens(tokens = { "w1" => "secret-token" })
    old = ENV["FETCHER_TOKENS"]
    ENV["FETCHER_TOKENS"] = tokens.transform_values { Digest::SHA256.hexdigest(_1) }.to_json
    yield
  ensure
    ENV["FETCHER_TOKENS"] = old
  end

  def fetcher_headers(token = "secret-token")
    { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
  end
end
