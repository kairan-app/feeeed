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
end
