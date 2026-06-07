require "test_helper"

class ItemsTest < ActionDispatch::IntegrationTest
  test "shows items published within one month from now" do
    item = create(:item, title: "Near Future Item", published_at: 3.weeks.from_now)

    get items_path

    assert_response :success
    assert_match(/Near Future Item/, response.body)
  end

  test "does not show items published more than one month from now" do
    item = create(:item, title: "Far Future Item", published_at: 2.months.from_now)

    get items_path

    assert_response :success
    assert_no_match(/Far Future Item/, response.body)
  end
end
