module Disco
  class << self
    def post(payload, channel: :default)
      webhook_url = webhook_url_for(channel)
      return if webhook_url.nil?

      payload = add_environment_prefix(payload)

      response = Faraday.post(webhook_url) do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = payload.to_json
      end
      handle_response(response, channel)
    end

    private

    def webhook_url_for(channel)
      # 環境変数DISCORD_WEBHOOK_URLが設定されていれば、それを優先
      return ENV["DISCORD_WEBHOOK_URL"] if ENV["DISCORD_WEBHOOK_URL"].present?

      # credentialsから取得
      urls = Rails.application.credentials.discord_webhook_urls || {}
      urls[channel] || urls[:default]
    end

    def add_environment_prefix(payload)
      return payload if Rails.env.production?

      env_name = Rails.env.capitalize
      prefix = "[#{env_name}] "

      if payload[:content].present?
        payload[:content] = prefix + payload[:content]
      elsif payload[:embeds].present? && payload[:embeds].first[:title].present?
        payload[:embeds].first[:title] = prefix + payload[:embeds].first[:title]
      end

      payload
    end

    def handle_response(response, channel)
      case response.status
      when 200..299
        puts "[Disco:#{channel}] Message sent successfully"
      else
        puts "[Disco:#{channel}] Error sending message: #{response.body}"
      end
    end
  end
end
