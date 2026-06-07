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
end
