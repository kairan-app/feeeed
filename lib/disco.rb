module Disco
  class << self
    def post(payload)
      webhook_url = ENV["DISCORD_WEBHOOK_URL"]
      return if webhook_url.nil?

      response = Faraday.post(webhook_url) do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = payload.to_json
      end
      handle_response(response)
    end

    private

    def handle_response(response)
      case response.status
      when 200..299
        puts "[Disco] Message sent successfully"
      else
        puts "[Disco] Error sending message: #{response.body}"
      end
    end
  end
end
