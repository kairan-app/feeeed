require "test_helper"

class My::Unreads::Channels::ItemsTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user)
    @channel = create(:channel)
    @user.subscribe(@channel)
  end

  test "has_more is false when exactly limit items remain" do
    # 6件のunread itemsを作成（最初に3件表示、残り3件）
    6.times do |i|
      create(:item, channel: @channel, published_at: i.hours.ago)
    end

    sign_in(@user)

    # offset=3, limit=3 でリクエスト（残り3件をすべて取得）
    get my_unreads_channel_items_path(
      channel_id: @channel.id,
      offset: 3,
      limit: 3,
      range_days: 7
    ), as: :turbo_stream

    assert_response :success

    # ボタンが消えることを確認（has_moreがfalseなので空のreplaceになる）
    assert_no_match(/Load more unreads/, response.body)
  end

  test "has_more is true when more items remain beyond limit" do
    # 7件のunread itemsを作成（最初に3件表示、残り4件）
    7.times do |i|
      create(:item, channel: @channel, published_at: i.hours.ago)
    end

    sign_in(@user)

    # offset=3, limit=3 でリクエスト（残り4件のうち3件取得）
    get my_unreads_channel_items_path(
      channel_id: @channel.id,
      offset: 3,
      limit: 3,
      range_days: 7
    ), as: :turbo_stream

    assert_response :success

    # ボタンが表示されることを確認（まだ1件残っている）
    assert_match(/Load more unreads/, response.body)
  end

  test "has_more is false when no items remain" do
    # 3件のunread itemsを作成（最初に3件表示、残り0件）
    3.times do |i|
      create(:item, channel: @channel, published_at: i.hours.ago)
    end

    sign_in(@user)

    # offset=3, limit=3 でリクエスト（残り0件）
    get my_unreads_channel_items_path(
      channel_id: @channel.id,
      offset: 3,
      limit: 3,
      range_days: 7
    ), as: :turbo_stream

    assert_response :success

    # ボタンが消えることを確認
    assert_no_match(/Load more unreads/, response.body)
  end
end
