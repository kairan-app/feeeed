require "test_helper"

class My::AppPasswordsTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user)
    sign_in(@user)
  end

  test "index shows active and revoked App Passwords" do
    _plain_active, active = AppPassword.issue!(user: @user, name: "Active One")
    _plain_revoked, revoked = AppPassword.issue!(user: @user, name: "Revoked One")
    revoked.revoke!

    get "/my/app_passwords"
    assert_response :success
    assert_match "Active One", response.body
    assert_match "Revoked One", response.body
    assert_match active.token_last_4, response.body
  end

  test "create issues a new App Password and shows the plain token once" do
    assert_difference "AppPassword.count", 1 do
      post "/my/app_passwords", params: { app_password: { name: "MacBook" } }
    end

    assert_response :success
    assert_match(/rururu_/, response.body)
    ap = @user.app_passwords.last
    assert_equal "MacBook", ap.name
  end

  test "create redirects back when name is blank" do
    assert_no_difference "AppPassword.count" do
      post "/my/app_passwords", params: { app_password: { name: "" } }
    end
    assert_response :redirect
  end

  test "destroy revokes the App Password (soft delete)" do
    _plain, ap = AppPassword.issue!(user: @user, name: "MacBook")

    assert_no_difference "AppPassword.count" do
      delete "/my/app_passwords/#{ap.id}"
    end

    assert_response :redirect
    assert ap.reload.revoked?
  end

  test "destroy does not touch another user's App Password" do
    other_user = create(:user)
    _plain, ap = AppPassword.issue!(user: other_user, name: "Theirs")

    delete "/my/app_passwords/#{ap.id}"
    assert_response :not_found

    assert_not ap.reload.revoked?
  end

  test "login is required" do
    open_session do |guest|
      guest.get "/my/app_passwords"
      assert_equal 302, guest.response.status
    end
  end
end
