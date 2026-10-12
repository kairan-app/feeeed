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

  test "相手のサイトが HTTP エラーを返したときは Sentry に送らない" do
    Httpc.stubs(:get_with_redirect_info).raises(Httpc::HTTPError.new("HTTP request failed with status 404: ", status: 404))
    Sentry.expects(:capture_exception).never
    Sentry.expects(:capture_message).never

    ChannelItemsUpdaterJob.perform_now(channel_id: @channel.id)
  end

  test "タイムアウトや接続の失敗は Sentry に送らない" do
    Httpc.stubs(:get_with_redirect_info).raises(Faraday::TimeoutError)
    Sentry.expects(:capture_exception).never

    ChannelItemsUpdaterJob.perform_now(channel_id: @channel.id)
  end

  test "フィードを解釈できないときは、1回の実行で warning を1件だけ送る" do
    Httpc.stubs(:get_with_redirect_info).returns({ body: "not a feed", final_url: @channel.feed_url, redirected: false })
    Sentry.expects(:capture_exception).never
    Sentry.expects(:capture_message).with("Could not parse the feed - channel_id: #{@channel.id}", has_entries(level: :warning)).once

    ChannelItemsUpdaterJob.perform_now(channel_id: @channel.id)
  end

  test "アプリのバグらしい例外は Sentry に送る" do
    Channel.any_instance.stubs(:update_info).raises(NoMethodError)
    Channel.any_instance.stubs(:fetch_and_save_items)
    Sentry.expects(:capture_exception).with(instance_of(NoMethodError), anything).once

    ChannelItemsUpdaterJob.perform_now(channel_id: @channel.id)
  end

  # #853: 前のジョブが長引いているうちに次のジョブが積まれると、同じフィードを二重に取りに行く
  # 待たされるかどうかは Solid Queue に積んだ結果で確かめる
  describe "同じチャンネルのジョブの重なり (#853)" do
    setup do
      @other = Channel.create!(title: "ほかのチャンネル", feed_url: "https://example.com/other.xml", site_url: "https://example.com")
      @original_adapter = ChannelItemsUpdaterJob.queue_adapter
      ChannelItemsUpdaterJob.queue_adapter = :solid_queue
      # Channel を作ったときに積まれたジョブが、セマフォを握ったままにならないようにする
      SolidQueue::Job.delete_all
      SolidQueue::Semaphore.delete_all
    end

    teardown do
      ChannelItemsUpdaterJob.queue_adapter = @original_adapter
    end

    test "同じチャンネルのジョブは同時に1つしか動かず、後から積んだものは待たされる" do
      ChannelItemsUpdaterJob.perform_later(channel_id: @channel.id)
      ChannelItemsUpdaterJob.perform_later(channel_id: @channel.id, mode: :only_recent)

      jobs = SolidQueue::Job.where(class_name: "ChannelItemsUpdaterJob").order(:id)
      assert_equal 2, jobs.count
      assert jobs.first.ready?
      assert jobs.second.blocked?
    end

    test "ほかのチャンネルのジョブは待たされない" do
      ChannelItemsUpdaterJob.perform_later(channel_id: @channel.id)
      ChannelItemsUpdaterJob.perform_later(channel_id: @other.id)

      jobs = SolidQueue::Job.where(class_name: "ChannelItemsUpdaterJob")
      assert_equal 2, jobs.count
      assert jobs.all?(&:ready?)
    end
  end
end
