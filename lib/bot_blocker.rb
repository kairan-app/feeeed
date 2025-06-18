class BotBlocker
  def initialize(app)
    @app = app
  end

  def call(env)
    request = Rack::Request.new(env)

    # 特定のボットのUser-Agentをブロック
    if blocked_user_agent?(request.user_agent)
      return blocked_response("User-Agent blocked")
    end

    # 既知のボットIPアドレスをブロック
    if blocked_ip?(request.ip)
      return blocked_response("IP blocked")
    end

    @app.call(env)
  end

  private

  def blocked_user_agent?(user_agent)
    return false if user_agent.nil?

    # ブロック対象のボット・クローラーのUser-Agentパターン
    blocked_patterns = [
      /SemrushBot/i,
      /AhrefsBot/i,
      /MJ12bot/i,
      /DotBot/i,
      /PetalBot/i,
      /BLEXBot/i,
      /YandexBot/i,
      /python-requests/i,
    ]

    blocked_patterns.any? { |pattern| user_agent.match?(pattern) }
  end

  def blocked_ip?(ip)
    return false if ip.nil?

    # ブロック対象のクローラーIPレンジ
    blocked_ip_ranges = [
      # 高頻度アクセスのクローラーIP（例）
      /^85\.208\.96\./,
      /^51\.222\.253\./,
      /^52\.167\.144\./,
      /^216\.244\.66\./,
      /^216\.73\.216\./
    ]

    blocked_ip_ranges.any? { |pattern| ip.match?(pattern) }
  end

  def blocked_response(reason)
    Rails.logger.info "Bot blocked: #{reason}"
    [403, { 'Content-Type' => 'text/plain' }, ["Access denied: #{reason}"]]
  end
end
