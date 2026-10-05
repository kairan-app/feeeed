require "test_helper"

class ChannelGroupWebhookTest < ActiveJob::TestCase
  setup do
    ActiveJob::Base.queue_adapter = :test
    @user = create(:user)
    @channel_group = create(:channel_group, owner: @user)
    Faraday.stubs(:post)
  end

  test ".notify はすべての webhook ぶんのジョブを積む" do
    2.times { |i| ChannelGroupWebhook.create!(user: @user, channel_group: @channel_group, url: "https://discord.com/api/webhooks/#{i}") }

    ChannelGroupWebhook.notify

    assert_enqueued_jobs 2, only: ChannelGroupWebhookNotifierJob
  end

  %w[discord slack].each do |service|
    test "#{service} に送るとき、channel を1件ずつ引かない" do
      host = service == "slack" ? "hooks.slack.com" : "discord.com"
      webhook = ChannelGroupWebhook.create!(user: @user, channel_group: @channel_group, url: "https://#{host}/hook")
      webhook.stubs(:sleep)
      3.times { @channel_group.channels << create(:item).channel }

      assert_no_queries_match(/FROM "channels" WHERE "channels"\."id" = /) do
        webhook.notify
      end
    end
  end
end
