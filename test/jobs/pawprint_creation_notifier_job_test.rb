require "test_helper"

class PawprintCreationNotifierJobTest < ActiveJob::TestCase
  setup do
    ActiveJob::Base.queue_adapter = :test
    channel = Channel.create!(
      title: "テストチャンネル",
      feed_url: "https://example.com/feed.xml",
      site_url: "https://example.com"
    )
    item = channel.items.create!(guid: "entry-1", title: "Entry 1", url: "https://example.com/1", published_at: 1.hour.ago)
    user = User.create!(name: "foo", email: "foo@example.com", icon_url: "https://example.com/icon.png", google_guid: "foo-guid")
    @pawprint = user.pawprints.create!(item:)
    clear_enqueued_jobs
  end

  test "Discordへの投稿ジョブを積む" do
    PawprintCreationNotifierJob.perform_now(@pawprint.id)

    assert_enqueued_jobs 1, only: DiscoPosterJob
  end

  test "足あとがもう外されていたら何もしない" do
    pawprint_id = @pawprint.id
    @pawprint.destroy!

    assert_nothing_raised do
      PawprintCreationNotifierJob.perform_now(pawprint_id)
    end

    assert_no_enqueued_jobs only: DiscoPosterJob
  end
end
