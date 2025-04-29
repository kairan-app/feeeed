require "test_helper"
require "ostruct"

class ChannelTest < ActiveSupport::TestCase
  setup do
    @feed_xml = File.read(Rails.root.join("test/fixtures/juneboku_nikki.xml"))
    OpenGraph.stubs(:new).returns(OpenStruct.new(image: nil))
  end

  test "should not save channel without title" do
    channel = Channel.new
    assert_not(channel.save, "保存に失敗する")
  end

  test "フィードのタイトルを正しく取得できる" do
    channel = Channel.add_by_xml(@feed_xml)
    assert_equal "juneboku", channel.title
  end

  test "フィードのURLを正しく取得できる" do
    channel = Channel.add_by_xml(@feed_xml)
    assert_equal "https://junebako.github.io/sff/juneboku/nikki.xml", channel.feed_url
  end
end
