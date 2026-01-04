class My::SubscriptionTagsController < MyController
  def edit
    @subscription_tag = current_user.subscription_tags.find(params[:id])
    @title = "Edit Tag"
  end

  def create
    @subscription_tag = current_user.subscription_tags.build(subscription_tag_params)

    if @subscription_tag.save
      redirect_to my_subscriptions_path
    else
      redirect_to my_subscriptions_path, alert: @subscription_tag.errors.full_messages.join(", ")
    end
  end

  def update
    @subscription_tag = current_user.subscription_tags.find(params[:id])

    if @subscription_tag.update(subscription_tag_params)
      redirect_to my_subscriptions_path
    else
      redirect_to my_subscriptions_path, alert: @subscription_tag.errors.full_messages.join(", ")
    end
  end

  def destroy
    @subscription_tag = current_user.subscription_tags.find(params[:id])
    @subscription_tag.destroy
    redirect_to my_subscriptions_path
  end

  def move_up
    @subscription_tag = current_user.subscription_tags.find(params[:id])
    @subscription_tag.move_up
    redirect_to my_subscriptions_path
  end

  def move_down
    @subscription_tag = current_user.subscription_tags.find(params[:id])
    @subscription_tag.move_down
    redirect_to my_subscriptions_path
  end

  private

  def subscription_tag_params
    params.require(:subscription_tag).permit(:name)
  end
end
