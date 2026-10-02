require "test_helper"

class ChannelRolloutTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @old = ENV["ROLLOUT_PERCENT"]
    @channel = create(:channel, last_items_checked_at: nil)
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
  end

  teardown { ENV["ROLLOUT_PERCENT"] = @old }

  test "ロールアウトの対象のチャンネルはジョブに積まない" do
    ENV["ROLLOUT_PERCENT"] = (@channel.id % 100 + 1).to_s

    assert_no_enqueued_jobs(only: ChannelItemsUpdaterJob) { Channel.fetch_and_save_items }
  end

  test "対象外のチャンネルは今までどおり積む" do
    ENV["ROLLOUT_PERCENT"] = (@channel.id % 100).to_s

    assert_enqueued_with(job: ChannelItemsUpdaterJob, args: [ { channel_id: @channel.id } ]) { Channel.fetch_and_save_items }
  end

  test "割合が 0 なら全部積む" do
    ENV["ROLLOUT_PERCENT"] = "0"

    assert_enqueued_with(job: ChannelItemsUpdaterJob, args: [ { channel_id: @channel.id } ]) { Channel.fetch_and_save_items }
  end
end
