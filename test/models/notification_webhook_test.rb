require "test_helper"

class NotificationWebhookTest < ActiveJob::TestCase
  setup do
    ActiveJob::Base.queue_adapter = :test
    @user = create(:user)
    Faraday.stubs(:post)
  end

  test ".notify は通知する時刻の webhook ぶんのジョブを積む" do
    target = NotificationWebhook.create!(user: @user, url: "https://discord.com/api/webhooks/1", notify_hour: Time.current.hour)
    NotificationWebhook.create!(user: @user, url: "https://discord.com/api/webhooks/2", notify_hour: (Time.current.hour + 1) % 24)

    assert_enqueued_with(job: NotificationWebhookNotifierJob, args: [ target.id ]) do
      NotificationWebhook.notify
    end
    assert_enqueued_jobs 1, only: NotificationWebhookNotifierJob
  end

  %w[discord slack].each do |service|
    test "pawprints を #{service} に送るとき、item と channel を1件ずつ引かない" do
      host = service == "slack" ? "hooks.slack.com" : "discord.com"
      webhook = NotificationWebhook.create!(user: @user, url: "https://#{host}/hook", mode: :my_pawprints, notify_hour: 0)
      webhook.stubs(:sleep)
      3.times { Pawprint.create!(user: @user, item: create(:item)) }

      assert_no_queries_match(/FROM "(items|channels)" WHERE "\1"\."id" = /) do
        webhook.notify
      end
    end

    test "購読中の item を #{service} に送るとき、channel を1件ずつ引かない" do
      host = service == "slack" ? "hooks.slack.com" : "discord.com"
      webhook = NotificationWebhook.create!(user: @user, url: "https://#{host}/hook", mode: :my_subscribed_items, notify_hour: 0)
      webhook.stubs(:sleep)
      3.times do
        item = create(:item)
        @user.subscriptions.create!(channel: item.channel)
      end

      assert_no_queries_match(/FROM "channels" WHERE "channels"\."id" = /) do
        webhook.notify
      end
    end
  end
end
