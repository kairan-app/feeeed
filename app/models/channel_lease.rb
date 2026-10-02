# fetcher (Rust) に貸し出し中のチャンネル。同じチャンネルと同じホストは、同時に1つの fetcher にしか貸し出さない
# (channel_id と host の一意制約で守る)。結果が届かないまま TTL を過ぎた lease は、次の貸し出しのときに消す
class ChannelLease < ApplicationRecord
  self.primary_key = :channel_id

  belongs_to :channel

  TTL = 10.minutes
  # feed_url からホストを取り出す式 (dispatcher の selectDueChannels と同じ)
  HOST_SQL = "lower(substring(channels.feed_url from '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:?#]+)'))".freeze

  class << self
    # チェックが必要なチャンネルを、ホストが重ならないように最大 max 件貸し出す
    def grant!(worker_name:, max:, rollout_percent:, now: Time.current)
      return [] if rollout_percent <= 0

      transaction do
        where(leased_until: ...now).delete_all
        candidates = due_channels_one_per_host(max:, rollout_percent:)
        next [] if candidates.empty?

        rows = candidates.map { |c|
          { channel_id: c.id, host: c.host, worker_name:, leased_until: now + TTL, created_at: now }
        }
        # 同時に来た別の貸し出しと、チャンネルかホストがぶつかった行は一意制約で飛ばす (ON CONFLICT DO NOTHING)
        # (insert_all は unique_by を省くと主キー (channel_id) だけを衝突先にして、host の衝突では例外になるので、SQL を直接書く)
        granted_ids = insert_skipping_conflicts(rows)
        where(channel_id: granted_ids).includes(:channel).to_a
      end
    end

    # lease がこのワーカーのもので期限内なら、期限を今から TTL 延ばして true を返す
    def renew(channel_id:, worker_name:, now: Time.current)
      where(channel_id:, worker_name:).where("leased_until > ?", now).update_all(leased_until: now + TTL) == 1
    end

    def release(channel_id:, worker_name:)
      where(channel_id:, worker_name:).delete_all
    end

    private

    def insert_skipping_conflicts(rows)
      values = rows.map { |r|
        sanitize_sql_array([ "(?, ?, ?, ?, ?)", r[:channel_id], r[:host], r[:worker_name], r[:leased_until], r[:created_at] ])
      }.join(", ")
      connection.select_values(<<~SQL.squish)
        INSERT INTO channel_leases (channel_id, host, worker_name, leased_until, created_at)
        VALUES #{values}
        ON CONFLICT DO NOTHING
        RETURNING channel_id
      SQL
    end

    # ホストごとに優先度の一番高いチャンネルを1つずつ選び、その中から優先度順に max 件
    def due_channels_one_per_host(max:, rollout_percent:)
      due = Channel.not_stopped.needs_check_now
        .where("channels.id % 100 < ?", rollout_percent)
        .select(:id, :feed_url, :site_url, :check_interval_hours, :last_items_checked_at)
        .select(Arel.sql("#{HOST_SQL} AS host"))
      # HOST_SQL の正規表現に ? があるので、find_by_sql の配列 (プレースホルダ) 形式は使わない
      Channel.find_by_sql(<<~SQL.squish)
        SELECT * FROM (
          SELECT DISTINCT ON (due.host) due.* FROM (#{due.to_sql}) due
          WHERE due.host IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM channel_leases l WHERE l.channel_id = due.id OR l.host = due.host
            )
          ORDER BY due.host, due.check_interval_hours, due.last_items_checked_at, due.id
        ) per_host
        ORDER BY per_host.check_interval_hours, per_host.last_items_checked_at, per_host.id
        LIMIT #{Integer(max)}
      SQL
    end
  end
end
