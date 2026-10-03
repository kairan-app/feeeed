# entries の多い取得結果の item の保存以降を行う (Fetcher::ResultsController から回ってくる)
class FetchResultApplyJob < ApplicationJob
  queue_as :default
  # 毎時の ChannelItemsUpdaterJob の山の後ろで待つと lease の TTL を過ぎてしまうので、先に動かす
  # (Solid Queue は priority の数字が小さいものから動かす)
  queue_with_priority(-10)

  def perform(channel_id:, worker_name:, entries:, latest_guids:)
    # 待っている間に lease が切れていたら、別のワーカーが同じチャンネルを処理しているかもしれないので何もしない。
    # lease も消さない。ワーカー名が同じでも、今ある行は後から貸し出した新しい lease かもしれない。
    # 保存しなかった entry は、次の取得で新しいものとしてまた送られてくる
    return unless ChannelLease.renew(channel_id:, worker_name:)

    begin
      applier = FetchResultApplier.new(channel: Channel.find(channel_id))
      applier.save_items!(entries, latest_guids:)
      applier.finish!
    ensure
      ChannelLease.release(channel_id:, worker_name:)
    end
  end
end
