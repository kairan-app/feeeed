# fetcher (Rust) 向けの API。セッションや CSRF は使わず、マシンごとのトークンで認証する
class Fetcher::BaseController < ActionController::API
  class InvalidBody < StandardError; end

  before_action :authenticate_worker!

  rescue_from InvalidBody, JSON::ParserError do
    head :unprocessable_content
  end

  private

  attr_reader :worker_name

  def authenticate_worker!
    token = request.headers["Authorization"].to_s.delete_prefix("Bearer ")
    @worker_name = FetcherToken.worker_name_for(token)
    head :unauthorized if @worker_name.nil?
  end

  def json_body
    @json_body ||= JSON.parse(request.raw_post).tap { raise InvalidBody unless _1.is_a?(Hash) }
  end
end
