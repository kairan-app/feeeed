class My::SubscriptionsController < MyController
  def index
    @subscriptions = current_user.subscriptions.includes(:channel, :subscription_tags).order(created_at: :desc)
    @subscription_tags = current_user.subscription_tags.ordered
    @title = "My Subscriptions"
  end

  def update
    @subscription = current_user.subscriptions.find(params[:id])
    @subscription_tags = current_user.subscription_tags.ordered
    tag_ids = params[:subscription_tag_ids] || []

    @subscription.subscription_tag_ids = tag_ids

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to my_subscriptions_path }
    end
  end
end
