require "test_helper"

class ItemTest < ActiveSupport::TestCase
  describe "dependent destroy" do
    test "Itemを削除すると紐づくitem_skipsも削除される" do
      item = create(:item)
      user = create(:user)
      ItemSkip.create!(user: user, item: item)

      assert_difference("ItemSkip.count", -1) do
        item.destroy!
      end
    end
  end
end
