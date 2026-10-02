require "test_helper"

class FetchResultApplierTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    @channel = create(:channel, title: "Old Title", feed_url: "https://a.example.com/feed.xml",
                                site_url: "https://a.example.com/", check_interval_hours: 24,
                                last_items_checked_at: 1.day.ago)
    @applier = FetchResultApplier.new(channel: @channel)
    Sentry.stubs(:capture_message)
    Sentry.stubs(:capture_exception)
  end

  def entry(guid, published_at: "2026-09-25T00:00:00Z", **attrs)
    { "guid" => guid, "title" => "Title #{guid}", "url" => "https://a.example.com/#{guid}",
      "image_url" => nil, "published_at" => published_at,
      "data" => { "entry_id" => guid, "summary" => "S #{guid}" } }.merge(attrs.stringify_keys)
  end

  def payload(**overrides)
    { "fetched" => true, "error" => nil, "final_url" => nil, "register_proxy_urls" => [],
      "channel" => { "title" => "New Title", "description" => "D", "site_url" => "https://a.example.com/",
                     "image_url" => nil, "applied_filters" => [], "filter_details" => {} },
      "entries" => [], "latest_guids" => [] }.merge(overrides.stringify_keys)
  end

  describe "valid_payload?" do
    test "最低限の形を確かめる" do
      assert FetchResultApplier.valid_payload?(payload)
      assert FetchResultApplier.valid_payload?({ "fetched" => false, "error" => { "kind" => "timeout", "message" => "x" } })
      assert_not FetchResultApplier.valid_payload?({ "fetched" => "yes" })
      assert_not FetchResultApplier.valid_payload?(payload(entries: "x"))
      assert_not FetchResultApplier.valid_payload?(payload(entries: [ "x" ]))
      assert_not FetchResultApplier.valid_payload?(payload(channel: "x"))
      assert_not FetchResultApplier.valid_payload?(payload(latest_guids: nil))
    end
  end

  describe "apply_channel!" do
    test "チャンネル情報を更新し、item の保存に進む" do
      assert @applier.apply_channel!(payload)
      assert_equal "New Title", @channel.reload.title
      assert_equal "D", @channel.description
    end

    test "channel が null なら更新しない" do
      assert @applier.apply_channel!(payload(channel: nil))
      assert_equal "Old Title", @channel.reload.title
    end

    test "バリデーションに通らないチャンネル情報は更新せずに進む" do
      assert @applier.apply_channel!(payload(channel: payload["channel"].merge("title" => "")))
      assert_equal "Old Title", @channel.reload.title
    end

    test "取得に失敗していたら何も更新せず、item の保存にも進まない" do
      assert_not @applier.apply_channel!({ "fetched" => false, "error" => { "kind" => "timeout", "message" => "t" } })
      assert_equal "Old Title", @channel.reload.title
    end

    test "リダイレクトしていたら feed_url を更新する" do
      assert @applier.apply_channel!(payload(final_url: "https://a.example.com/new.xml"))
      assert_equal "https://a.example.com/new.xml", @channel.reload.feed_url
    end

    test "リダイレクト先が既存のチャンネルなら停止し、item の保存に進まない" do
      existing = create(:channel, feed_url: "https://a.example.com/new.xml")

      assert_not @applier.apply_channel!(payload(final_url: "https://a.example.com/new.xml"))
      assert_equal "https://a.example.com/feed.xml", @channel.reload.feed_url
      assert_equal "Old Title", @channel.title
      assert_match "##{existing.id}", @channel.stopper.reason
    end

    test "register_proxy_urls のホストを proxy の要るドメインに登録する" do
      @applier.apply_channel!(payload(register_proxy_urls: [ "https://blocked.example.com/feed.xml" ]))
      assert ProxyRequiredDomain.exists?(domain: "blocked.example.com")
    end
  end

  describe "save_items!" do
    test "entries を保存し、latest_guids に含まれるものだけ通知する" do
      result = nil
      assert_enqueued_jobs 1, only: ItemCreationNotifierJob do
        result = @applier.save_items!([ entry("g1"), entry("g2") ], latest_guids: [ "g2", "https://a.example.com/g2" ])
      end

      assert_equal({ created: 2, skipped: 0 }, result)
      item = @channel.items.find_by!(guid: "g1")
      assert_equal "Title g1", item.title
      assert_equal Time.utc(2026, 9, 25), item.published_at
      assert_equal "S g1", item.data["summary"]
    end

    test "既に同じ guid の item があれば、Sentry に送らずに飛ばす" do
      create(:item, channel: @channel, guid: "g1")
      Sentry.expects(:capture_message).never

      result = @applier.save_items!([ entry("g1") ], latest_guids: [ "g1" ])

      assert_equal({ created: 0, skipped: 1 }, result)
    end

    test "バリデーションに落ちた entry は Sentry に warning を送って飛ばし、残りは保存する" do
      Sentry.expects(:capture_message).with(regexp_matches(/validation failed/), has_entry(level: :warning)).once

      result = @applier.save_items!([ entry("bad", published_at: nil), entry("good") ], latest_guids: [])

      assert_equal({ created: 1, skipped: 1 }, result)
      assert @channel.items.exists?(guid: "good")
    end

    test "association のキャッシュに無効な Item を残さない (#828)" do
      @applier.save_items!([ entry("bad", published_at: nil) ], latest_guids: [])

      assert_nothing_raised { @channel.update!(title: "Still Valid") }
    end
  end

  describe "finish!" do
    test "チェック済みを記録し、間隔とスケジュールを計算し直す" do
      @applier.save_items!([ entry("g1", published_at: 1.hour.ago.iso8601), entry("g2", published_at: 2.days.ago.iso8601),
                             entry("g3", published_at: 3.days.ago.iso8601) ], latest_guids: [])

      @applier.finish!

      @channel.reload
      assert_operator @channel.last_items_checked_at, :>, 1.minute.ago
      assert_equal 1, @channel.check_interval_hours
    end

    test "1つの手順が失敗しても残りの手順は進む" do
      @channel.stubs(:set_check_interval!).raises(RuntimeError, "boom")
      @channel.expects(:adjust_schedules!).once
      Sentry.expects(:capture_exception).once

      @applier.finish!

      assert_operator @channel.reload.last_items_checked_at, :>, 1.minute.ago
    end
  end
end
