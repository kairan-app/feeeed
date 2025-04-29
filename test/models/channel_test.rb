require "test_helper"
require "ostruct"

class ChannelTest < ActiveSupport::TestCase
  test "should not save channel without title" do
    channel = Channel.new
    assert_not(channel.save, "保存に失敗する")
  end

  describe "Add channel by juneboku_nikki.xml" do
    setup do
      @feed_xml = File.read(Rails.root.join("test/fixtures/juneboku_nikki.xml"))
      @og_image_url = "https://example.com/image.jpg"
      OpenGraph.stubs(:new).returns(OpenStruct.new(image: @og_image_url))
    end

    test "Channelが期待通りに保存される" do
      channel = Channel.add_by_xml(@feed_xml)
      assert_equal "純朴日記", channel.title
      assert_equal "junebokuが2019年8月23日から書き続けている毎日更新の日記です", channel.description
      assert_equal "https://junebako.github.io/sff/juneboku/nikki.xml", channel.feed_url
      assert_equal "https://scrapbox.io/juneboku", channel.site_url
      assert_equal @og_image_url, channel.image_url
    end
  end

  describe "Add channel by youtube_hana.xml" do
    setup do
      @feed_xml = File.read(Rails.root.join("test/fixtures/youtube_hana.xml"))
      @og_image_url = "https://example.com/image.jpg"
      @description = "HANA official YouTube channel"
      OpenGraph.stubs(:new).returns(OpenStruct.new(image: @og_image_url, description: @description))
    end

    test "Channelが期待通りに保存される" do
      channel = Channel.add_by_xml(@feed_xml)
      assert_equal "HANA official", channel.title
      assert_equal @description, channel.description
      assert_equal "https://www.youtube.com/feeds/videos.xml?channel_id=UCJqWKSEmDP9ph3iVYCKyl3Q", channel.feed_url
      assert_equal "https://www.youtube.com/channel/UCJqWKSEmDP9ph3iVYCKyl3Q", channel.site_url
      assert_equal @og_image_url, channel.image_url
    end
  end
end
