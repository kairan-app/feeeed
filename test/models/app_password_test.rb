require "test_helper"

class AppPasswordTest < ActiveSupport::TestCase
  setup do
    @user = create(:user)
  end

  test "issue! returns plain token with rururu_ prefix" do
    plain, record = AppPassword.issue!(user: @user, name: "MacBook")

    assert plain.start_with?("rururu_")
    assert_equal @user, record.user
    assert_equal "MacBook", record.name
    assert_equal plain.last(4), record.token_last_4
    assert_equal AppPassword.digest(plain), record.token_digest
    assert_nil record.last_used_at
    assert_nil record.revoked_at
  end

  test "authenticate returns user for a valid plain token and touches last_used_at" do
    plain, record = AppPassword.issue!(user: @user, name: "MacBook")

    travel 1.minute do
      assert_equal @user, AppPassword.authenticate(plain)
      assert_not_nil record.reload.last_used_at
    end
  end

  test "authenticate returns nil for an invalid token" do
    AppPassword.issue!(user: @user, name: "MacBook")
    assert_nil AppPassword.authenticate("rururu_invalid")
    assert_nil AppPassword.authenticate(nil)
    assert_nil AppPassword.authenticate("")
  end

  test "authenticate returns nil for a revoked token" do
    plain, record = AppPassword.issue!(user: @user, name: "MacBook")
    record.revoke!

    assert_nil AppPassword.authenticate(plain)
  end

  test "revoke! sets revoked_at" do
    _plain, record = AppPassword.issue!(user: @user, name: "MacBook")

    assert_not record.revoked?
    record.revoke!
    assert record.revoked?
    assert_not_nil record.revoked_at
  end

  test "active and revoked scopes" do
    _plain1, active_record = AppPassword.issue!(user: @user, name: "Active")
    _plain2, revoked_record = AppPassword.issue!(user: @user, name: "Revoked")
    revoked_record.revoke!

    assert_includes AppPassword.active, active_record
    assert_not_includes AppPassword.active, revoked_record
    assert_includes AppPassword.revoked, revoked_record
    assert_not_includes AppPassword.revoked, active_record
  end

  test "name is required" do
    ap = AppPassword.new(user: @user, token_digest: "x", token_last_4: "abcd")
    assert_not ap.valid?
    assert ap.errors[:name].any?
  end
end
