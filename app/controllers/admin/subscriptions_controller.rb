class Admin::SubscriptionsController < AdminController
  def index
    @subscriptions = Subscription
      .includes(:user, :channel, :subscription_tags)
      .order(created_at: :desc)
      .page(params[:page])
      .per(50)
    @title = "Admin Subscriptions"
  end
end
