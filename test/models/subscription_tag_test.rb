require "test_helper"

class SubscriptionTagTest < ActiveSupport::TestCase
  describe "validations" do
    test "requires a name" do
      user = create(:user)
      tag = user.subscription_tags.build(name: nil)
      assert_not tag.valid?
      assert_includes tag.errors[:name], "can't be blank"
    end

    test "requires name to be unique per user" do
      user = create(:user)
      user.subscription_tags.create!(name: "Tech")
      tag = user.subscription_tags.build(name: "Tech")
      assert_not tag.valid?
      assert_includes tag.errors[:name], "has already been taken"
    end
  end

  describe "position management" do
    describe "#set_position_on_create" do
      test "sets position to 0 for the first tag" do
        user = create(:user)
        tag = user.subscription_tags.create!(name: "First")
        assert_equal 0, tag.position
      end

      test "sets position to next sequential value for additional tags" do
        user = create(:user)
        user.subscription_tags.create!(name: "First")
        second = user.subscription_tags.create!(name: "Second")
        third = user.subscription_tags.create!(name: "Third")

        assert_equal 1, second.position
        assert_equal 2, third.position
      end
    end

    describe "#normalize_positions_after_destroy" do
      test "normalizes positions after a tag is destroyed" do
        user = create(:user)
        first = user.subscription_tags.create!(name: "First")
        second = user.subscription_tags.create!(name: "Second")
        third = user.subscription_tags.create!(name: "Third")

        second.destroy

        assert_equal 0, first.reload.position
        assert_equal 1, third.reload.position
      end

      test "normalizes positions when first tag is destroyed" do
        user = create(:user)
        first = user.subscription_tags.create!(name: "First")
        second = user.subscription_tags.create!(name: "Second")
        third = user.subscription_tags.create!(name: "Third")

        first.destroy

        assert_equal 0, second.reload.position
        assert_equal 1, third.reload.position
      end
    end

    describe ".normalize_positions" do
      test "resets positions to sequential 0-based values" do
        user = create(:user)
        first = user.subscription_tags.create!(name: "First")
        second = user.subscription_tags.create!(name: "Second")
        third = user.subscription_tags.create!(name: "Third")

        # Simulate gaps in positions
        first.update_column(:position, 5)
        second.update_column(:position, 10)
        third.update_column(:position, 15)

        SubscriptionTag.normalize_positions(user)

        assert_equal 0, first.reload.position
        assert_equal 1, second.reload.position
        assert_equal 2, third.reload.position
      end
    end
  end

  describe "move operations" do
    setup do
      @user = create(:user)
      @first = @user.subscription_tags.create!(name: "First")
      @second = @user.subscription_tags.create!(name: "Second")
      @third = @user.subscription_tags.create!(name: "Third")
    end

    describe "#move_up" do
      test "swaps position with the previous tag" do
        @second.move_up

        assert_equal 1, @first.reload.position
        assert_equal 0, @second.reload.position
        assert_equal 2, @third.reload.position
      end

      test "does nothing when already at the top" do
        @first.move_up

        assert_equal 0, @first.reload.position
        assert_equal 1, @second.reload.position
        assert_equal 2, @third.reload.position
      end
    end

    describe "#move_down" do
      test "swaps position with the next tag" do
        @second.move_down

        assert_equal 0, @first.reload.position
        assert_equal 2, @second.reload.position
        assert_equal 1, @third.reload.position
      end

      test "does nothing when already at the bottom" do
        @third.move_down

        assert_equal 0, @first.reload.position
        assert_equal 1, @second.reload.position
        assert_equal 2, @third.reload.position
      end
    end
  end
end
