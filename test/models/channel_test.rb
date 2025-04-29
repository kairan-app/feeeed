require "test_helper"
require "ostruct"

class ChannelTest < ActiveSupport::TestCase
  test "should not save channel without title" do
    channel = Channel.new
    assert_not(channel.save, "保存に失敗する")
  end

  describe "Add channel by juneboku_nikki.xml" do
    setup do
      @feed_url = "https://junebako.github.io/sff/juneboku/nikki.xml"
      @feed_xml = File.read(Rails.root.join("test/fixtures/juneboku_nikki.xml"))
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

  describe "Add channel by youtube_hana.xml" do
    setup do
      @feed_url = "https://www.youtube.com/feeds/videos.xml?channel_id=UCJqWKSEmDP9ph3iVYCKyl3Q"
      @feed_xml = File.read(Rails.root.join("test/fixtures/youtube_hana.xml"))
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

  describe "Add channel by juneboku_life.xml" do
    setup do
      @feed_url = "https://rss.listen.style/p/juneboku-life/rss"
      @feed_xml = File.read(Rails.root.join("test/fixtures/juneboku_life.xml"))

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
