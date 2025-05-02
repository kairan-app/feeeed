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

          Feedbag.stubs(:find).with(@site_url).returns([@feed_url])
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
end
