require "test_helper"

class ChannelGroupsTest < ActionDispatch::IntegrationTest
  # #811: Itemごとにpawprintsとchannelを引くN+1が出ていた
  test "Itemが何件あってもpawprintsとchannelsを1回ずつしか引かない" do
    user = create(:user)
    channel_group = create(:channel_group, owner: user)
    3.times do
      channel = create(:channel)
      channel_group.channels << channel
      2.times { create(:item, channel:, published_at: 1.hour.ago) }
    end
    sign_in(user)

    assert_queries_match(/FROM "pawprints"/, count: 1) do
      assert_queries_match(/FROM "channels" WHERE "channels"."id" IN/, count: 1) do
        get channel_group_path(channel_group)
      end
    end

    assert_response :success
  end
end
