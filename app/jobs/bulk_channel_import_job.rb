class BulkChannelImportJob < ApplicationJob
  queue_as :default

  def perform(user_id, urls)
    user = User.find(user_id)
    results = { success: [], failed: [], duplicate: [] }

    urls.each do |url|
      begin
        # 既存チャンネルのチェック
        existing = Channel.find_by(feed_url: url)
        if existing
          results[:duplicate] << { url: url, channel: existing }
          next
        end

        # 新規チャンネルの追加
        channel = Channel.add(url)
        if channel&.persisted?
          results[:success] << { url: url, channel: channel }
        else
          results[:failed] << { url: url, reason: "フィードの保存に失敗しました" }
        end
      rescue Feedjira::NoParserAvailable => e
        results[:failed] << { url: url, reason: "フィードが見つかりませんでした" }
      rescue StandardError => e
        results[:failed] << { url: url, reason: "エラー: #{e.message}" }
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

  def notify_discord(user, results)
    content = [
      "@#{user.name} のフィード一括登録が完了しました",
      "成功: #{results[:success].size}件",
      "重複: #{results[:duplicate].size}件",
      "失敗: #{results[:failed].size}件"
    ].join("\n")

    DiscoPosterJob.perform_later(content: content)
  end
end
