require "test_helper"

class ChannelFixedScheduleTest < ActiveSupport::TestCase
  setup do
    @channel = create(:channel)
  end

  test "validates day_of_week range" do
    schedule = @channel.fixed_schedules.build(hour: 10)

    # Valid values
    (0..6).each do |day|
      schedule.day_of_week = day
      assert schedule.valid?, "Day of week #{day} should be valid"
    end

    # Invalid values
    [-1, 7, 10].each do |day|
      schedule.day_of_week = day
      assert_not schedule.valid?, "Day of week #{day} should be invalid"
    end
  end

  test "validates hour range" do
    schedule = @channel.fixed_schedules.build(day_of_week: 1)

    # Valid values
    (0..23).each do |hour|
      schedule.hour = hour
      assert schedule.valid?, "Hour #{hour} should be valid"
    end

    # Invalid values
    [-1, 24, 30].each do |hour|
      schedule.hour = hour
      assert_not schedule.valid?, "Hour #{hour} should be invalid"
    end
  end

  test "prevents duplicate schedules for same channel" do
    @channel.fixed_schedules.create!(day_of_week: 1, hour: 10)

    duplicate = @channel.fixed_schedules.build(day_of_week: 1, hour: 10)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:channel_id], "has already been taken"
  end

  test "allows same schedule for different channels" do
    other_channel = create(:channel)

    @channel.fixed_schedules.create!(day_of_week: 1, hour: 10)
    other_schedule = other_channel.fixed_schedules.build(day_of_week: 1, hour: 10)

    assert other_schedule.valid?
  end

  test "for_current_hour scope returns correct schedules" do
    now = Time.current

    # Create a schedule for the current hour
    current_schedule = @channel.fixed_schedules.create!(
      day_of_week: now.wday,
      hour: now.hour
    )

    # Create a schedule for a different hour
    other_schedule = @channel.fixed_schedules.create!(
      day_of_week: now.wday,
      hour: (now.hour + 1) % 24
    )

    # Only the current hour schedule should be returned
    schedules = ChannelFixedSchedule.for_current_hour
    assert_includes schedules, current_schedule
    assert_not_includes schedules, other_schedule
  end
end
