class Admin::UsersController < AdminController
  def index
    @users = User
      .select("users.*, MAX(ahoy_events.time) AS last_event_at")
      .joins("LEFT JOIN ahoy_events ON ahoy_events.user_id = users.id")
      .includes(subscription_tags: :subscription_taggings)
      .group("users.id")
      .order("last_event_at DESC NULLS LAST")
    @title = "Admin Users"
  end
end
