require "test_helper"

class WelcomeControllerTest < ActionDispatch::IntegrationTest
  test "renders the newest items of each channel on the top page" do
    channel = create(:channel, title: "Design Weekly")
    create(:item, channel: channel, title: "Older post", published_at: 2.days.ago)
    create(:item, channel: channel, title: "Newest post", published_at: 1.hour.ago)

    get root_path

    assert_response :success
    assert_select "h3", text: "Design Weekly"
    assert_select "h4", text: "Newest post"
  end
end
