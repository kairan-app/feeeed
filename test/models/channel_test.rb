require "test_helper"
require "ostruct"

class ChannelTest < ActiveSupport::TestCase
  describe "Validation" do
    test "should not save channel without title" do
      channel = Channel.new
      assert_not(channel.save, "保存に失敗する")
    end
  end

  describe "Add" do
    describe "Add Site (Auto discovery)" do
      describe "june29_jp.html" do
        setup do
          @site_url = "https://june29.jp/"
          @site_html = File.read(Rails.root.join("test/fixtures/files/june29_jp.html"))
          @feed_url = "https://june29.jp/feed.xml"
          @feed_xml = File.read(Rails.root.join("test/fixtures/files/june29_jp.xml"))

          Feedbag.stubs(:find).with(@site_url).returns([ @feed_url ])
          Httpc.stubs(:get).with(@site_url).returns(@site_html)
          Httpc.stubs(:get).with(@feed_url).returns(@feed_xml)
          OpenGraph.stubs(:new).returns(OpenStruct.new())
        end

        test "サイトURLからフィードURLを自動検出してChannelが保存される" do
          channel = Channel.add(@site_url)
          assert_equal "#june29jp", channel.title
          assert_equal "Recent content on #june29jp", channel.description
          assert_equal @feed_url, channel.feed_url
          assert_equal @site_url, channel.site_url
        end
      end
    end

    describe "Add Feed" do
      describe "juneboku_nikki.xml" do
        setup do
          @feed_url = "https://junebako.github.io/sff/juneboku/nikki.xml"
          @feed_xml = File.read(Rails.root.join("test/fixtures/files/juneboku_nikki.xml"))
          @og_image_url = "https://example.com/image.jpg"

          OpenGraph.stubs(:new).returns(OpenStruct.new(image: @og_image_url))
          Httpc.stubs(:get).with(@feed_url).returns(@feed_xml)
        end

        test "Channelが期待通りに保存される" do
          channel = Channel.add(@feed_url)
          assert_equal "純朴日記", channel.title
          assert_equal "junebokuが2019年8月23日から書き続けている毎日更新の日記です", channel.description
          assert_equal @feed_url, channel.feed_url
          assert_equal "https://scrapbox.io/juneboku", channel.site_url
          assert_equal @og_image_url, channel.image_url
        end
      end

      describe "youtube_hana.xml" do
        setup do
          @feed_url = "https://www.youtube.com/feeds/videos.xml?channel_id=UCJqWKSEmDP9ph3iVYCKyl3Q"
          @feed_xml = File.read(Rails.root.join("test/fixtures/files/youtube_hana.xml"))
          @og_image_url = "https://example.com/image.jpg"
          @description = "HANA official YouTube channel"

          OpenGraph.stubs(:new).returns(OpenStruct.new(image: @og_image_url, description: @description))
          Httpc.stubs(:get).with(@feed_url).returns(@feed_xml)
        end

        test "Channelが期待通りに保存される" do
          channel = Channel.add(@feed_url)
          assert_equal "HANA official", channel.title
          assert_equal @description, channel.description
          assert_equal @feed_url, channel.feed_url
          assert_equal "https://www.youtube.com/channel/UCJqWKSEmDP9ph3iVYCKyl3Q", channel.site_url
          assert_equal @og_image_url, channel.image_url
        end
      end

      describe "juneboku_life.xml" do
        setup do
          @feed_url = "https://rss.listen.style/p/juneboku-life/rss"
          @feed_xml = File.read(Rails.root.join("test/fixtures/files/juneboku_life.xml"))

          Httpc.stubs(:get).with(@feed_url).returns(@feed_xml)
        end

        test "Channelが期待通りに保存される" do
          channel = Channel.add(@feed_url)
          assert_equal "純朴声活", channel.title
          assert_equal "純朴の生活の様子を声と音でお届けします", channel.description
          assert_equal @feed_url, channel.feed_url
          assert_equal "https://listen.style/p/juneboku-life", channel.site_url
          assert_equal "https://image.listen.style/p/01hk4fekbzqwpdqf67597t3t78/images/DIhZaWQc2o2ny8FUQfNfzzOizf5OpTMdEogiSSv0.png", channel.image_url
        end
      end
    end
  end

  describe "Check intervals" do
    test "needs_check_now scope includes channels never checked" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed",
        last_items_checked_at: nil,
        check_interval_hours: 1
      )

      assert_includes Channel.needs_check_now, channel
    end

    test "needs_check_now scope includes channels past their interval" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed2",
        last_items_checked_at: 2.hours.ago,
        check_interval_hours: 1
      )

      assert_includes Channel.needs_check_now, channel
    end

    test "needs_check_now scope excludes channels within their interval" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed3",
        last_items_checked_at: 30.minutes.ago,
        check_interval_hours: 1
      )

      assert_not_includes Channel.needs_check_now, channel
    end

    test "by_check_priority orders by interval then by last check time" do
      channel1 = Channel.create!(
        title: "Channel 1",
        feed_url: "http://example.com/feed4",
        check_interval_hours: 4,
        last_items_checked_at: 1.hour.ago
      )
      channel2 = Channel.create!(
        title: "Channel 2",
        feed_url: "http://example.com/feed5",
        check_interval_hours: 1,
        last_items_checked_at: 2.hours.ago
      )

      ordered = Channel.by_check_priority.limit(2)
      assert_equal channel2, ordered.first
    end

    test "mark_items_checked! updates last_items_checked_at" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed6"
      )
      old_time = channel.last_items_checked_at

      channel.mark_items_checked!

      assert_not_equal old_time, channel.last_items_checked_at
      assert channel.last_items_checked_at > 1.minute.ago
    end

    test "set_check_interval! sets correct intervals based on item frequency" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed7"
      )

      # 1週間以内に3つ以上のアイテム：1時間間隔
      3.times do |i|
        channel.items.create!(
          title: "Recent item #{i}",
          url: "http://example.com/recent#{i}",
          guid: "recent-guid-#{i}",
          published_at: (i + 1).days.ago
        )
      end

      channel.set_check_interval!
      assert_equal 1, channel.check_interval_hours

      # 2週間以内に2つのアイテム（1週間以内に3つ未満）：3時間間隔
      channel.items.destroy_all
      2.times do |i|
        channel.items.create!(
          title: "Item #{i}",
          url: "http://example.com/item#{i}",
          guid: "guid-#{i}",
          published_at: (i + 8).days.ago
        )
      end

      channel.set_check_interval!
      assert_equal 3, channel.check_interval_hours

      # 1ヶ月以内に2つのアイテム：4時間間隔
      channel.items.destroy_all
      2.times do |i|
        channel.items.create!(
          title: "Item #{i}",
          url: "http://example.com/item#{i}",
          guid: "guid-#{i}",
          published_at: (i + 20).days.ago
        )
      end

      channel.set_check_interval!
      assert_equal 4, channel.check_interval_hours

      # 2ヶ月以内に1つのアイテム：12時間間隔
      channel.items.destroy_all
      channel.items.create!(
        title: "Old item",
        url: "http://example.com/old",
        guid: "old-guid",
        published_at: 45.days.ago
      )

      channel.set_check_interval!
      assert_equal 12, channel.check_interval_hours

      # アイテムがない、または2ヶ月以上古い：24時間間隔
      channel.items.destroy_all
      channel.items.create!(
        title: "Very old item",
        url: "http://example.com/very-old",
        guid: "very-old-guid",
        published_at: 3.months.ago
      )

      channel.set_check_interval!
      assert_equal 24, channel.check_interval_hours
    end
  end

  describe "Fixed schedules" do
    test "add_schedule creates a new schedule" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed"
      )

      assert_difference "channel.fixed_schedules.count", 1 do
        channel.add_schedule(day_of_week: 1, hour: 10)
      end

      schedule = channel.fixed_schedules.last
      assert_equal 1, schedule.day_of_week
      assert_equal 10, schedule.hour
    end

    test "remove_schedule deletes the schedule" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed"
      )
      channel.add_schedule(day_of_week: 1, hour: 10)

      assert_difference "channel.fixed_schedules.count", -1 do
        channel.remove_schedule(day_of_week: 1, hour: 10)
      end
    end

    test "analyze_publishing_patterns detects patterns" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed"
      )

      # Create items with pattern: Monday 10:00
      base_time = Time.zone.parse("2024-01-01 10:00") # This is a Monday
      5.times do |i|
        channel.items.create!(
          title: "Monday item #{i}",
          url: "http://example.com/mon#{i}",
          guid: "mon-guid-#{i}",
          published_at: base_time + i.weeks
        )
      end

      # Create items with pattern: Thursday 10:00
      base_time = Time.zone.parse("2024-01-04 10:00") # This is a Thursday
      3.times do |i|
        channel.items.create!(
          title: "Thursday item #{i}",
          url: "http://example.com/thu#{i}",
          guid: "thu-guid-#{i}",
          published_at: base_time + i.weeks
        )
      end

      patterns = channel.analyze_publishing_patterns(item_count: 10)

      # Monday 10:00 should be the most frequent
      assert_equal [ 1, 10 ], patterns.keys.first
      assert_equal 5, patterns[[ 1, 10 ]]
      assert_equal 3, patterns[[ 4, 10 ]]
    end

    test "adjust_schedules adds schedules for frequent patterns" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed"
      )

      # Create 6 items on Monday 10:00 (meets threshold)
      base_time = Time.zone.parse("2024-01-01 10:00")
      6.times do |i|
        channel.items.create!(
          title: "Item #{i}",
          url: "http://example.com/item#{i}",
          guid: "guid-#{i}",
          published_at: base_time + i.weeks
        )
      end

      # Create other items to reach 20 total
      14.times do |i|
        channel.items.create!(
          title: "Other #{i}",
          url: "http://example.com/other#{i}",
          guid: "other-guid-#{i}",
          published_at: 1.week.ago + i.hours
        )
      end

      assert_difference "channel.fixed_schedules.count", 1 do
        result = channel.adjust_schedules!
        assert_equal 1, result[:added].count
        assert_equal 0, result[:removed].count
      end

      schedule = channel.fixed_schedules.last
      assert_equal 1, schedule.day_of_week
      assert_equal 10, schedule.hour
    end

    test "adjust_schedules removes schedules for infrequent patterns" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed"
      )

      # Create existing schedule
      channel.add_schedule(day_of_week: 1, hour: 10)

      # Create only 3 items on Monday 10:00 (below threshold)
      base_time = Time.zone.parse("2024-01-01 10:00")
      3.times do |i|
        channel.items.create!(
          title: "Monday item #{i}",
          url: "http://example.com/mon#{i}",
          guid: "mon-guid-#{i}",
          published_at: base_time + i.weeks
        )
      end

      # Create other items to reach 20 total
      17.times do |i|
        channel.items.create!(
          title: "Other #{i}",
          url: "http://example.com/other#{i}",
          guid: "other-guid-#{i}",
          published_at: 1.week.ago + i.hours
        )
      end

      assert_difference "channel.fixed_schedules.count", -1 do
        result = channel.adjust_schedules!
        assert_equal 0, result[:added].count
        assert_equal 1, result[:removed].count
      end
    end

    test "adjust_schedules skips channels with insufficient items" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed"
      )

      # Create only 19 items (below 20 threshold)
      19.times do |i|
        channel.items.create!(
          title: "Item #{i}",
          url: "http://example.com/item#{i}",
          guid: "guid-#{i}",
          published_at: Time.current - i.days
        )
      end

      result = channel.adjust_schedules!
      assert_equal [], result[:added]
      assert_equal [], result[:removed]
    end

    test "adjust_schedules removes all schedules for inactive channels" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed"
      )

      # Create existing schedules
      channel.add_schedule(day_of_week: 1, hour: 10)
      channel.add_schedule(day_of_week: 4, hour: 10)

      # Create 20 items, all older than 1 month
      20.times do |i|
        channel.items.create!(
          title: "Old item #{i}",
          url: "http://example.com/old#{i}",
          guid: "old-guid-#{i}",
          published_at: 2.months.ago - i.days
        )
      end

      assert_difference "channel.fixed_schedules.count", -2 do
        result = channel.adjust_schedules!
        assert_equal [], result[:added]
        assert_equal [ [ 1, 10 ], [ 4, 10 ] ], result[:removed].sort
      end
    end

    test "scheduled_for_current_hour scope includes channels with current schedules" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed"
      )

      now = Time.current
      channel.add_schedule(day_of_week: now.wday, hour: now.hour)

      assert_includes Channel.scheduled_for_current_hour, channel
    end

    test "needs_check_now includes scheduled channels" do
      channel = Channel.create!(
        title: "Test Channel",
        feed_url: "http://example.com/feed",
        last_items_checked_at: 1.hour.ago,
        check_interval_hours: 24
      )

      # Normally wouldn't need check (last check was 1 hour ago, interval is 24 hours)
      assert_not_includes Channel.needs_check_now, channel

      # Add schedule for current hour
      now = Time.current
      channel.add_schedule(day_of_week: now.wday, hour: now.hour)

      # Now should be included due to schedule
      assert_includes Channel.needs_check_now, channel
    end
  end

  describe "Feed URL redirect handling" do
    describe "リダイレクトが検出された場合" do
      setup do
        @old_url = "https://listen.style/p/juneboku-life/rss"
        @new_url = "https://rss.listen.style/p/juneboku-life/rss"
        @feed_xml = File.read(Rails.root.join("test/fixtures/files/juneboku_life.xml"))

        # Httpc.get_with_redirect_infoをスタブ（リダイレクトあり）
        Httpc.stubs(:get_with_redirect_info).with(@old_url).returns({
          body: @feed_xml,
          final_url: @new_url,
          redirected: true
        })

        # FeedNormalizerは実際のメソッドを呼ぶ（リダイレクト情報が追加される）
        # OpenGraphのモックも必要
        OpenGraph.stubs(:new).returns(OpenStruct.new())
      end

      test "旧URLでチャンネルが存在する場合、feed_urlが新URLに更新される" do
        # 旧URLでチャンネルを作成
        existing_channel = Channel.create!(
          title: "純朴声活",
          feed_url: @old_url,
          site_url: "https://listen.style/p/juneboku-life"
        )

        # 旧URLで再度追加を試みる
        channel = Channel.add(@old_url)

        # 同じチャンネルが返される
        assert_equal existing_channel.id, channel.id
        # feed_urlが新URLに更新されている
        assert_equal @new_url, channel.feed_url
        # チャンネルの総数は増えていない
        assert_equal 1, Channel.where(title: "純朴声活").count
      end

      test "旧URLでチャンネルが存在しない場合、新URLでチャンネルが作成される" do
        # 旧URLで追加
        channel = Channel.add(@old_url)

        # 新URLで作成される
        assert_equal @new_url, channel.feed_url
        assert_equal "純朴声活", channel.title
      end

      test "既存チャンネルのfetch_and_save_itemsでリダイレクトが検出された場合、feed_urlが更新される" do
        # 旧URLでチャンネルを作成
        channel = Channel.create!(
          title: "純朴声活",
          feed_url: @old_url,
          site_url: "https://listen.style/p/juneboku-life"
        )

        # 既存のfeed_urlを保存
        original_feed_url = channel.feed_url

        # アイテムを取得
        channel.fetch_and_save_items(:only_recent)

        # feed_urlが更新されている
        channel.reload
        assert_equal @new_url, channel.feed_url
        assert_not_equal original_feed_url, channel.feed_url
      end
    end

    describe "リダイレクトが検出されない場合" do
      setup do
        @feed_url = "https://example.com/feed.xml"
        @feed_xml = File.read(Rails.root.join("test/fixtures/files/juneboku_life.xml"))

        # Httpc.get_with_redirect_infoをスタブ（リダイレクトなし）
        Httpc.stubs(:get_with_redirect_info).with(@feed_url).returns({
          body: @feed_xml,
          final_url: @feed_url,
          redirected: false
        })

        OpenGraph.stubs(:new).returns(OpenStruct.new())
      end

      test "feed_urlは変更されない" do
        channel = Channel.add(@feed_url)
        assert_equal @feed_url, channel.feed_url
      end
    end
  end
end
