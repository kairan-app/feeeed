require "test_helper"

class FetchResultApplyJobTest < ActiveJob::TestCase
  setup do
    @channel = create(:channel, feed_url: "https://a.example.com/feed.xml", last_items_checked_at: nil)
    ChannelLease.grant!(worker_name: "w1", max: 1, rollout_percent: 100)
    @entries = [ { "guid" => "g1", "title" => "T", "url" => "https://a.example.com/g1", "image_url" => nil,
                   "published_at" => "2026-09-25T00:00:00Z", "data" => {} } ]
  end

  test "item を保存してチェック済みにし、lease を消す" do
    FetchResultApplyJob.perform_now(channel_id: @channel.id, worker_name: "w1", entries: @entries, latest_guids: [])

    assert @channel.items.exists?(guid: "g1")
    assert_not_nil @channel.reload.last_items_checked_at
    assert_not ChannelLease.exists?(channel_id: @channel.id)
  end

  test "lease が切れていたら何もしない (別のワーカーが処理しているかもしれない)" do
    ChannelLease.where(channel_id: @channel.id).update_all(leased_until: 1.minute.ago)

    FetchResultApplyJob.perform_now(channel_id: @channel.id, worker_name: "w1", entries: @entries, latest_guids: [])

    assert_not @channel.items.exists?(guid: "g1")
    assert_nil @channel.reload.last_items_checked_at
  end

  test "renew に失敗したら lease の行を消さない (同じワーカー名の新しい lease かもしれない)" do
    ChannelLease.where(channel_id: @channel.id).update_all(leased_until: 1.minute.ago)

    FetchResultApplyJob.perform_now(channel_id: @channel.id, worker_name: "w1", entries: @entries, latest_guids: [])

    assert ChannelLease.exists?(channel_id: @channel.id)
  end

  test "default キューの他のジョブより先に動く優先度で積む" do
    assert_equal(-10, FetchResultApplyJob.new.priority)
  end
end
