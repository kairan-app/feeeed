require "test_helper"

class ItemCreationNotifierJobTest < ActiveJob::TestCase
  setup do
    ActiveJob::Base.queue_adapter = :test
    channel = Channel.create!(
      title: "テストチャンネル",
      feed_url: "https://example.com/feed.xml",
      site_url: "https://example.com"
    )
    @item = channel.items.create!(guid: "entry-1", title: "Entry 1", url: "https://example.com/1", published_at: 1.hour.ago)
    clear_enqueued_jobs
  end

  test "フィードを取り直さずにDiscordへの投稿ジョブを積む" do
    Httpc.expects(:get).never

    ItemCreationNotifierJob.perform_now(@item.id)

    assert_enqueued_jobs 1, only: DiscoPosterJob
  end
end
