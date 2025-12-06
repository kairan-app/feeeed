require "test_helper"

class GuestAccessTest < ActionDispatch::IntegrationTest
  setup do
    @channel = create(:channel)
    @item = create(:item, channel: @channel)
    @user = create(:user)
    @channel_group = create(:channel_group, owner: @user)
  end

  test "guest can access root page" do
    get "/"
    assert_response :success
  end

  test "guest can access channels index" do
    get "/channels"
    assert_response :success
  end

  test "guest can access channel show" do
    get "/channels/#{@channel.id}"
    assert_response :success
  end

  test "guest can access items index" do
    get "/items"
    assert_response :success
  end

  test "guest can access channel_groups index" do
    get "/channel_groups"
    assert_response :success
  end

  test "guest can access channel_group show" do
    get "/channel_groups/#{@channel_group.id}"
    assert_response :success
  end

  test "guest can access user show" do
    get "/@#{@user.name}"
    assert_response :success
  end

  test "guest can access user pawprints as json" do
    get "/@#{@user.name}/pawprints", as: :json
    assert_response :success
  end

  test "guest can access user subscribed_items as json" do
    get "/@#{@user.name}/subscribed_items", as: :json
    assert_response :success
  end

  test "guest can access about page" do
    get "/about"
    assert_response :success
  end

  test "guest can access terms page" do
    get "/terms"
    assert_response :success
  end

  test "guest can access privacy page" do
    get "/privacy"
    assert_response :success
  end

  # join_requests/new requires pending_auth session (redirects without it)
  test "guest is redirected from join_requests/new without pending auth" do
    get "/join_requests/new"
    assert_response :redirect
  end
end
