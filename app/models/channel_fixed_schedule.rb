class ChannelFixedSchedule < ApplicationRecord
  belongs_to :channel

  validates :day_of_week, inclusion: { in: 0..6 }
  validates :hour, inclusion: { in: 0..23 }
  validates :channel_id, uniqueness: { scope: [ :day_of_week, :hour ] }

  scope :for_current_hour, -> {
    current_time = Time.current
    where(
      day_of_week: current_time.wday,
      hour: current_time.hour
    )
  }
end
