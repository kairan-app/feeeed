require "test_helper"

class ItemsTest < ActionDispatch::IntegrationTest
  test "shows items published in the past" do
    item = create(:item, title: "Past Item", published_at: 1.hour.ago)

    get items_path

    assert_response :success
    assert_match(/Past Item/, response.body)
  end

  test "does not show items published in the future" do
    item = create(:item, title: "Future Item", published_at: 1.day.from_now)

    get items_path

    assert_response :success
    assert_no_match(/Future Item/, response.body)
  end

  test "件数を数えるときに channels を JOIN しない" do
    create(:item, published_at: 1.hour.ago)

    assert_no_queries_match(/COUNT\(\*\) FROM \(SELECT DISTINCT/) do
      get items_path
    end
    assert_response :success
  end

  test "Item.max_pages までのページは開ける" do
    get items_path(page: Item.max_pages)
    assert_response :success
  end

  test "Item.max_pages を超えるページは 404 を返す" do
    get items_path(page: Item.max_pages + 1)
    assert_response :not_found
  end

  test "チャンネルの Item も Item.max_pages を超えるページは 404 を返す" do
    channel = create(:channel)

    get channel_path(channel, page: Item.max_pages)
    assert_response :success

    get channel_path(channel, page: Item.max_pages + 1)
    assert_response :not_found
  end
end
