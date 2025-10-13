class BulkChannelImportJob < ApplicationJob
  queue_as :default

  def perform(user_id, existing_urls, new_urls, skipped_count = 0)
    user = User.find(user_id)
    results = { success: [], failed: [], skipped_count: skipped_count }

    # 既存チャンネルの処理（外部アクセスなし）
    existing_urls.each do |url|
      existing = Channel.find_by(feed_url: url)
      if existing
        # 既存チャンネルをサブスクライブ
        subscribe_channel(user, existing)
        results[:success] << { url: url, channel: existing }
      end
    end

    # 新規チャンネルの処理（外部アクセスあり、100件制限適用済み）
    new_urls.each do |url|
      begin
        # 新規チャンネルの追加
        channel = Channel.add(url)
        if channel&.persisted?
          # 新規チャンネルをサブスクライブ
          subscribe_channel(user, channel)
          results[:success] << { url: url, channel: channel }
        else
          results[:failed] << { url: url, reason: "Failed to save feed" }
        end
      rescue Feedjira::NoParserAvailable => e
        results[:failed] << { url: url, reason: "Feed not found" }
      rescue StandardError => e
        results[:failed] << { url: url, reason: "Error: #{e.message}" }
      end
    end

    # 結果をメールで通知
    BulkImportMailer.result_notification(user, results).deliver_later if results.values.any?(&:present?)

    # Discord通知
    if results[:success].any? || results[:failed].any?
      notify_discord(user, results)
    end
  end

  private

  def subscribe_channel(user, channel)
    return false if user.subscriptions.exists?(channel: channel)

    user.subscriptions.create!(channel: channel)
    true
  rescue StandardError => e
    Rails.logger.error "Subscription failed: #{e.message}"
    false
  end

  def notify_discord(user, results)
    content = [
      "@#{user.name} bulk feed import completed",
      "Success: #{results[:success].size}",
      "Failed: #{results[:failed].size}"
    ]

    if results[:skipped_count] > 0
      content << "Skipped: #{results[:skipped_count]} (new feeds over 100 limit)"
    end

    content = content.join("\n")

    DiscoPosterJob.perform_later(content: content, channel: :user_activities)
  end
end
