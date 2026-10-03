# 新着チェックを fetcher (Rust) へ段階的に移すための割合。channel_id % 100 がこれ未満のチャンネルを fetcher に任せる。
# 0 なら全部 Rails (ChannelItemsUpdaterJob) が取る
module FetcherRollout
  def self.percent
    ENV.fetch("ROLLOUT_PERCENT", "0").to_i.clamp(0, 100)
  end

  def self.covers?(channel_id)
    channel_id % 100 < percent
  end
end
