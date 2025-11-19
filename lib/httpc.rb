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

  # リダイレクト情報を含めてレスポンスを返すメソッド
  def self.get_with_redirect_info(url)
    connection = Faraday.new do |builder|
      builder.use FaradayMiddleware::FollowRedirects
      builder.use :cookie_jar
      builder.adapter Faraday.default_adapter
    end

    response = connection.get(url)
    handle_response_with_redirect_info(response, url)
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

  def self.handle_response_with_redirect_info(response, original_url)
    case response.status
    when 200..299
      final_url = response.env.url.to_s
      {
        body: response.body,
        final_url: final_url,
        redirected: final_url != original_url
      }
    else
      raise "HTTP request failed with status #{response.status}: #{response.body}"
    end
  end
end
