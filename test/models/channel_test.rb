require "test_helper"

class ChannelTest < ActiveSupport::TestCase
  test "should not save channel without title" do
    channel = Channel.new
    assert(channel.save, "保存されてはいけません")
  end
end 
