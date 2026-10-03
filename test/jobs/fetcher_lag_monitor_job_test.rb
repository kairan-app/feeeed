require "test_helper"

class FetcherLagMonitorJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    @old = ENV["ROLLOUT_PERCENT"]
    ENV["ROLLOUT_PERCENT"] = "100"
  end

  teardown { ENV["ROLLOUT_PERCENT"] = @old }

  def lagging_channels(count)
    create_list(:channel, count, check_interval_hours: 1, last_items_checked_at: 3.hours.ago)
    clear_enqueued_jobs
  end

  test "遅れているチャンネルが10件を超えたら Discord に投稿する" do
    lagging_channels(11)

    assert_enqueued_with(job: DiscoPosterJob) { FetcherLagMonitorJob.perform_now }
    assert_match "11", enqueued_jobs.last[:args].first["content"]
  end

  test "10件以下なら投稿しない" do
    lagging_channels(10)

    assert_no_enqueued_jobs(only: DiscoPosterJob) { FetcherLagMonitorJob.perform_now }
  end

  test "間隔 + 1時間以内なら遅れに数えない" do
    create_list(:channel, 11, check_interval_hours: 1, last_items_checked_at: 90.minutes.ago)
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: DiscoPosterJob) { FetcherLagMonitorJob.perform_now }
  end

  test "停止中のチャンネルは数えない" do
    lagging_channels(11)
    ChannelStopper.create!(channel: Channel.first, reason: "test")

    assert_no_enqueued_jobs(only: DiscoPosterJob) { FetcherLagMonitorJob.perform_now }
  end

  test "割合が 0 なら何もしない" do
    ENV["ROLLOUT_PERCENT"] = "0"
    lagging_channels(11)

    assert_no_enqueued_jobs(only: DiscoPosterJob) { FetcherLagMonitorJob.perform_now }
  end
end
