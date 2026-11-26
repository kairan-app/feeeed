require "test_helper"

class PawprintTest < ActiveSupport::TestCase
  # #922: パースできない URL だと Addressable::URI::InvalidURIError で通知ジョブが落ちていた
  describe "to_discord_embed" do
    setup do
      @item = create(:item, url: "https://example.com/a")
      user = User.create!(name: "foo", email: "foo@example.com", icon_url: "https://example.com/icon.png", google_guid: "foo-guid")
      @pawprint = user.pawprints.create!(item: @item)
    end

    test "author の name はチャンネル名と URL のホスト" do
      assert_equal "#{@item.channel.title} | example.com", @pawprint.to_discord_embed[:author][:name]
    end

    test "パースできない URL ならチャンネル名だけにする" do
      @item.update_column(:url, "http://exa mple.com/")
      assert_equal @item.channel.title, @pawprint.reload.to_discord_embed[:author][:name]
    end
  end
end
