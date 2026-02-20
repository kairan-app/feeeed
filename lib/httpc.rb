require "faraday"
require "faraday_middleware"
require "faraday-cookie_jar"

class Httpc
  PROXY_TRIGGERING_ERRORS = [
    Faraday::ConnectionFailed,
    Faraday::TimeoutError
  ].freeze

  PROXY_TRIGGERING_STATUSES = [ 403 ].freeze

  def self.get(url)
    if proxy_available? && ProxyRequiredDomain.required?(url)
      return get_via_proxy(url)
    end

    response = direct_get(url)
    handle_response(response)
  rescue *PROXY_TRIGGERING_ERRORS => e
    raise e unless proxy_available?

    retry_via_proxy(url) { |proxy_response| handle_response(proxy_response) }
  end

  def self.get_with_redirect_info(url)
    if proxy_available? && ProxyRequiredDomain.required?(url)
      return get_with_redirect_info_via_proxy(url)
    end

    response = direct_get(url)

    if proxy_available? && PROXY_TRIGGERING_STATUSES.include?(response.status)
      return retry_via_proxy_with_redirect_info(url)
    end

    handle_response_with_redirect_info(response, url)
  rescue *PROXY_TRIGGERING_ERRORS => e
    raise e unless proxy_available?

    retry_via_proxy_with_redirect_info(url)
  end

  def self.proxy_available?
    ENV["FEED_PROXY_URL"].present? && ENV["FEED_PROXY_SECRET"].present?
  end

  private

  def self.direct_get(url)
    connection = Faraday.new do |builder|
      builder.use FaradayMiddleware::FollowRedirects
      builder.use :cookie_jar
      builder.adapter Faraday.default_adapter
    end

    connection.get(url)
  end

  def self.proxy_connection
    Faraday.new(url: ENV["FEED_PROXY_URL"]) do |builder|
      builder.adapter Faraday.default_adapter
    end
  end

  def self.get_via_proxy(url)
    response = proxy_connection.get("/") do |req|
      req.headers["X-Proxy-Secret"] = ENV["FEED_PROXY_SECRET"]
      req.headers["X-Target-URL"] = url
    end

    handle_response(response)
  end

  def self.get_with_redirect_info_via_proxy(url)
    response = proxy_connection.get("/") do |req|
      req.headers["X-Proxy-Secret"] = ENV["FEED_PROXY_SECRET"]
      req.headers["X-Target-URL"] = url
    end

    handle_proxy_response_with_redirect_info(response, url)
  end

  def self.retry_via_proxy(url)
    Rails.logger.info "[Httpc] Direct request failed for #{url}, retrying via proxy"

    response = proxy_connection.get("/") do |req|
      req.headers["X-Proxy-Secret"] = ENV["FEED_PROXY_SECRET"]
      req.headers["X-Target-URL"] = url
    end

    if response.status.between?(200, 299)
      ProxyRequiredDomain.register!(url)
      Rails.logger.info "[Httpc] Registered #{URI.parse(url).host} as proxy-required domain"
    end

    yield response
  end

  def self.retry_via_proxy_with_redirect_info(url)
    Rails.logger.info "[Httpc] Direct request failed for #{url}, retrying via proxy"

    response = proxy_connection.get("/") do |req|
      req.headers["X-Proxy-Secret"] = ENV["FEED_PROXY_SECRET"]
      req.headers["X-Target-URL"] = url
    end

    if response.status.between?(200, 299)
      ProxyRequiredDomain.register!(url)
      Rails.logger.info "[Httpc] Registered #{URI.parse(url).host} as proxy-required domain"
    end

    handle_proxy_response_with_redirect_info(response, url)
  end

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

  def self.handle_proxy_response_with_redirect_info(response, original_url)
    case response.status
    when 200..299
      final_url = response.headers["X-Original-URL"] || original_url
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
