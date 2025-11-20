class ChannelItemsUpdaterJob < ApplicationJob
  def perform(channel_id:, mode: :only_non_existing)
    channel = Channel.find(channel_id)

    begin
      channel.update_info
      # リダイレクトでfeed_urlが更新された場合、メモリ上のオブジェクトを最新の状態にする
      channel.reload
    rescue StandardError => e
      handle_error(e, channel, "Failed to update channel info")
    end

    begin
      channel.fetch_and_save_items(mode)
    rescue StandardError => e
      handle_error(e, channel, "Failed to fetch and save items")
    end

    begin
      channel.mark_items_checked!
    rescue StandardError => e
      handle_error(e, channel, "Failed to mark items checked")
    end
  end

  private

  def handle_error(error, channel, context)
    # Sentryにエラーを送信（スタックトレース付き）
    Sentry.capture_exception(error, extra: {
      channel_id: channel.id,
      channel_title: channel.title,
      feed_url: channel.feed_url,
      context: context
    })

    # コンパクトなログ出力
    logger.error "[ChannelItemsUpdaterJob] #{context} - Channel: #{channel.id} (#{channel.title}) - Error: #{error.class.name}: #{error.message}"
  end
end
