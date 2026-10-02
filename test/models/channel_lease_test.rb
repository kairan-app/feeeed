require "test_helper"

class ChannelLeaseTest < ActiveSupport::TestCase
  def due_channel(host, **attrs)
    create(:channel, feed_url: "https://#{host}/#{SecureRandom.hex(4)}/feed.xml", last_items_checked_at: nil, **attrs)
  end

  def grant(max: 8, rollout_percent: 100, worker_name: "w1", now: Time.current)
    ChannelLease.grant!(worker_name:, max:, rollout_percent:, now:)
  end

  test "チェックが必要なチャンネルを貸し出し、lease を登録する" do
    channel = due_channel("a.example.com")

    leases = grant

    assert_equal [ channel.id ], leases.map(&:channel_id)
    lease = leases.first
    assert_equal "a.example.com", lease.host
    assert_equal "w1", lease.worker_name
    assert_in_delta 10.minutes.from_now, lease.leased_until, 5.seconds
    assert_equal channel.feed_url, lease.channel.feed_url
  end

  test "チェックの必要がないチャンネルは貸し出さない" do
    due_channel("a.example.com", last_items_checked_at: 1.minute.ago, check_interval_hours: 1)

    assert_empty grant
  end

  test "停止中のチャンネルは貸し出さない" do
    channel = due_channel("a.example.com")
    ChannelStopper.create!(channel:, reason: "test")

    assert_empty grant
  end

  test "ロールアウトの割合の外のチャンネルは貸し出さない" do
    channel = due_channel("a.example.com")
    percent = channel.id % 100

    assert_empty grant(rollout_percent: percent)
    assert_equal [ channel.id ], grant(rollout_percent: percent + 1).map(&:channel_id)
  end

  test "割合が 0 なら何も貸し出さない" do
    due_channel("a.example.com")

    assert_empty grant(rollout_percent: 0)
  end

  test "同じバッチの中でホストが重ならない" do
    due_channel("a.example.com")
    due_channel("a.example.com")
    due_channel("b.example.com")

    leases = grant

    assert_equal %w[a.example.com b.example.com], leases.map(&:host).sort
  end

  test "lease 中のチャンネルと、lease 中のホストのチャンネルは貸し出さない" do
    first = due_channel("a.example.com")
    due_channel("a.example.com")

    assert_equal [ first.id ], grant.map(&:channel_id)
    assert_empty grant(worker_name: "w2")
  end

  test "ホストは大文字小文字を区別しない" do
    due_channel("A.Example.com")
    due_channel("a.example.COM")

    assert_equal 1, grant.size
  end

  test "期限切れの lease は消して、また貸し出す" do
    channel = due_channel("a.example.com")
    grant(now: 11.minutes.ago)

    leases = grant(worker_name: "w2")

    assert_equal [ channel.id ], leases.map(&:channel_id)
    assert_equal "w2", leases.first.worker_name
  end

  test "max 件までしか貸し出さない" do
    3.times { |i| due_channel("h#{i}.example.com") }

    assert_equal 2, grant(max: 2).size
  end

  test "チェック間隔の短いものから貸し出す" do
    slow = due_channel("slow.example.com", check_interval_hours: 24)
    fast = due_channel("fast.example.com", check_interval_hours: 1)

    assert_equal [ fast.id ], grant(max: 1).map(&:channel_id)
    assert_equal [ slow.id ], grant(max: 1).map(&:channel_id)
  end

  test "一意制約でぶつかった行は返さない" do
    channel = due_channel("a.example.com")
    # 同時に来た別の貸し出しが、選んだあと・登録する前に同じホストを取った状況を作る
    ChannelLease.stubs(:due_channels_one_per_host).returns(
      Channel.select("channels.*, 'a.example.com' AS host").where(id: channel.id).to_a
    )
    ChannelLease.insert_all!([ { channel_id: create(:channel, feed_url: "https://a.example.com/other.xml").id,
                                 host: "a.example.com", worker_name: "w2",
                                 leased_until: 10.minutes.from_now, created_at: Time.current } ])

    assert_empty grant
  end

  describe "renew" do
    test "自分の期限内の lease なら期限を延ばして true を返す" do
      channel = due_channel("a.example.com")
      grant(now: 5.minutes.ago)

      assert ChannelLease.renew(channel_id: channel.id, worker_name: "w1")
      assert_in_delta 10.minutes.from_now, ChannelLease.find(channel.id).leased_until, 5.seconds
    end

    test "他のワーカーの lease なら false" do
      channel = due_channel("a.example.com")
      grant

      assert_not ChannelLease.renew(channel_id: channel.id, worker_name: "w2")
    end

    test "期限切れなら false" do
      channel = due_channel("a.example.com")
      grant(now: 11.minutes.ago)

      assert_not ChannelLease.renew(channel_id: channel.id, worker_name: "w1")
    end
  end

  test "release は自分の lease だけを消す" do
    channel = due_channel("a.example.com")
    grant

    assert_equal 0, ChannelLease.release(channel_id: channel.id, worker_name: "w2")
    assert_equal 1, ChannelLease.release(channel_id: channel.id, worker_name: "w1")
    assert_not ChannelLease.exists?(channel_id: channel.id)
  end

  describe "FetcherRollout" do
    test "ROLLOUT_PERCENT を 0〜100 に丸めて読む" do
      with_env("ROLLOUT_PERCENT" => nil) { assert_equal 0, FetcherRollout.percent }
      with_env("ROLLOUT_PERCENT" => "10") { assert_equal 10, FetcherRollout.percent }
      with_env("ROLLOUT_PERCENT" => "150") { assert_equal 100, FetcherRollout.percent }
      with_env("ROLLOUT_PERCENT" => "-1") { assert_equal 0, FetcherRollout.percent }
    end

    test "covers? は channel_id % 100 が割合未満か" do
      with_env("ROLLOUT_PERCENT" => "10") do
        assert FetcherRollout.covers?(209)
        assert_not FetcherRollout.covers?(210)
      end
    end
  end

  private

  def with_env(vars)
    old = vars.keys.index_with { ENV[_1] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end
end
