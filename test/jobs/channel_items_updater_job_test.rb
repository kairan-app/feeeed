require "test_helper"

class ChannelItemsUpdaterJobTest < ActiveJob::TestCase
  setup do
    @channel = Channel.create!(
      title: "テストチャンネル",
      feed_url: "https://example.com/feed.xml",
      site_url: "https://example.com",
      last_items_checked_at: 1.day.ago
    )

    Sentry.stubs(:capture_exception)
  end

  test "非ASCIIを含むBINARYのエラーメッセージでも落ちずにチェック日時を進める" do
    message = "HTTP request failed with status 404: <html>見つかりません</html>".b
    Httpc.stubs(:get_with_redirect_info).raises(RuntimeError, message)

    ChannelItemsUpdaterJob.perform_now(channel_id: @channel.id)

    assert_operator @channel.reload.last_items_checked_at, :>, 1.minute.ago
  end

  test "非ASCIIを含むBINARYの本文で404が返っても落ちずにチェック日時を進める" do
    response = OpenStruct.new(status: 404, body: "<html>見つかりません</html>".b)
    Httpc.stubs(:proxy_available?).returns(false)
    Httpc.stubs(:direct_get).returns(response)

    ChannelItemsUpdaterJob.perform_now(channel_id: @channel.id)

    assert_operator @channel.reload.last_items_checked_at, :>, 1.minute.ago
  end
end
