class Admin::UsersController < AdminController
  def index
    seven_days_ago = 7.days.ago

    active_user_ids = Ahoy::Event
      .where("time > ?", seven_days_ago)
      .select(:user_id)
      .distinct
      .pluck(:user_id)

    base_query = User
      .select("users.*, MAX(ahoy_events.time) AS last_event_at")
      .joins("LEFT JOIN ahoy_events ON ahoy_events.user_id = users.id")
      .includes(subscription_tags: :subscription_taggings)
      .group("users.id")

    @active_users = base_query.where(id: active_user_ids).order(id: :desc)
    @inactive_users = base_query.where.not(id: active_user_ids).order(id: :desc)

    @title = "Admin Users"
  end
end
