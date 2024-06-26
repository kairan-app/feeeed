require "faraday"
require "faraday_middleware"
require "faraday-cookie_jar"

class Httpc
  def self.get(url)
    connection = Faraday.new do |builder|
      builder.use FaradayMiddleware::FollowRedirects
      builder.use :cookie_jar
      builder.adapter Faraday.default_adapter
    end

    response = connection.get(url)
    handle_response(response)
  end

  private

  def self.handle_response(response)
    case response.status
    when 200..299
      response.body
    else
      raise "HTTP request failed with status #{response.status}: #{response.body}"
    end
  end
end
