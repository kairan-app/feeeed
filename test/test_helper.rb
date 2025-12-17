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
