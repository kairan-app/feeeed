# fetcher (Rust) が止まっていないかを見る。ロールアウトの対象で、最後のチェックから
# チェック間隔 + 1時間以上たっているチャンネルが THRESHOLD 件を超えたら Discord に知らせる。
# fetcher が止まっても Rails は代わりに取らないので、ここで気づいて手で対応する
class FetcherLagMonitorJob < ApplicationJob
  queue_as :default

  THRESHOLD = 10

  def perform
    percent = FetcherRollout.percent
    return if percent.zero?

    lagging = Channel.not_stopped
      .where("channels.id % 100 < ?", percent)
      .where("channels.last_items_checked_at < NOW() - ((channels.check_interval_hours || ' hours')::interval + interval '1 hour')")
      .count
    return if lagging <= THRESHOLD

    DiscoPosterJob.perform_later(
      content: "[Fetcher] #{lagging} channels are overdue (last check older than interval + 1h). Is the fetcher running?",
      channel: :admin
    )
  end
end
