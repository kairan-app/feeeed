class UserProfileWidget < ApplicationRecord
  belongs_to :user

  enum :widget_type, {
    owned_channels: "owned_channels",
    owned_channel_recent_items: "owned_channel_recent_items",
    subscribed_channels: "subscribed_channels",
    publish_punchcard: "publish_punchcard",
    pawprints_punchcard: "pawprints_punchcard"
  }

  validates :widget_type, presence: true
  validates :widget_type, uniqueness: { scope: :user_id }

  before_validation :set_position_on_create, on: :create
  after_destroy :normalize_positions_after_destroy

  scope :ordered, -> { order(:position) }

  def move_up
    swap_with = user.profile_widgets.where("position < ?", position).order(position: :desc).first
    return unless swap_with

    self.class.transaction do
      swap_with.position, self.position = self.position, swap_with.position
      swap_with.save!
      save!
    end
  end

  def move_down
    swap_with = user.profile_widgets.where("position > ?", position).order(position: :asc).first
    return unless swap_with

    self.class.transaction do
      swap_with.position, self.position = self.position, swap_with.position
      swap_with.save!
      save!
    end
  end

  def self.normalize_positions(user)
    user.profile_widgets.ordered.each_with_index do |widget, index|
      widget.update_column(:position, index)
    end
  end

  private

  def set_position_on_create
    self.position = user.profile_widgets.maximum(:position).to_i
    self.position += 1 if user.profile_widgets.exists?
  end

  def normalize_positions_after_destroy
    self.class.normalize_positions(user)
  end
end
