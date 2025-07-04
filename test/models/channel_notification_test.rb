require "test_helper"

class ChannelNotificationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    # ActiveJobをテストアダプターに設定
    ActiveJob::Base.queue_adapter = :test

    @channel = Channel.create!(
      title: "Test Channel",
      feed_url: "https://example.com/feed.xml",
      description: "Test Description"
    )
  end

  test "notify_channel_change ignores last_items_checked_at changes" do
    # 最初の作成通知をクリア
    clear_enqueued_jobs

    # last_items_checked_atのみを変更
    @channel.update!(last_items_checked_at: Time.current)

    # Discord通知ジョブが実行されないことを確認
    assert_enqueued_jobs 0, only: DiscoPosterJob
  end

  test "notify_channel_change ignores updated_at changes" do
    # 最初の作成通知をクリア
    clear_enqueued_jobs

    # touch を使ってupdated_atのみを更新
    @channel.touch

    # Discord通知ジョブが実行されないことを確認
    assert_enqueued_jobs 0, only: DiscoPosterJob
  end

  test "notify_channel_change sends notification for meaningful changes" do
    # 最初の作成通知をクリア
    clear_enqueued_jobs

    # titleを変更
    assert_enqueued_jobs 1, only: DiscoPosterJob do
      @channel.update!(title: "New Title")
    end
  end

  test "notify_channel_change sends notification for description changes" do
    # 最初の作成通知をクリア
    clear_enqueued_jobs

    # descriptionを変更
    assert_enqueued_jobs 1, only: DiscoPosterJob do
      @channel.update!(description: "New Description")
    end
  end

  test "notify_channel_change ignores combined changes with only ignored fields" do
    # 最初の作成通知をクリア
    clear_enqueued_jobs

    # last_items_checked_atとupdated_atを同時に変更
    @channel.assign_attributes(
      last_items_checked_at: Time.current
    )
    @channel.save!

    # Discord通知ジョブが実行されないことを確認
    assert_enqueued_jobs 0, only: DiscoPosterJob
  end

  test "notify_channel_change sends notification when meaningful fields change with ignored fields" do
    # 最初の作成通知をクリア
    clear_enqueued_jobs

    # titleとlast_items_checked_atを同時に変更
    assert_enqueued_jobs 1, only: DiscoPosterJob do
      @channel.update!(
        title: "New Title",
        last_items_checked_at: Time.current
      )
    end
  end
end
