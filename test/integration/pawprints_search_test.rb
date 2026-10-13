require "test_helper"

class PawprintsSearchTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user)
    sign_in(@user)
    channel = create(:channel, title: "Ruby Weekly")
    Ownership.create!(user: @user, channel: channel)
    @user.paw(create(:item, channel: channel, title: "Hello"), memo: nil)
    other_channel = create(:channel, title: "Python Weekly")
    Ownership.create!(user: @user, channel: other_channel)
    @user.paw(create(:item, channel: other_channel, title: "Goodbye"), memo: nil)
  end

  %w[all my to_me].each do |scope|
    test "scope=#{scope} でチャンネル名を大文字小文字を区別せずに探せる" do
      get pawprints_path(scope: scope, pawprint_q: { memo_or_item_title_or_item_channel_title_i_cont: "ruby" })

      assert_response :success
      assert_match(/Hello/, response.body)
      assert_no_match(/Goodbye/, response.body)
    end
  end

  test "検索フォームは大文字小文字を区別しない述語で送る" do
    get pawprints_path

    assert_select "input[name='pawprint_q[memo_or_item_title_or_item_channel_title_i_cont]']"
  end
end
