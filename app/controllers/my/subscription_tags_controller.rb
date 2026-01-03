class My::SubscriptionTagsController < MyController
  def create
    next_position = current_user.subscription_tags.maximum(:position).to_i + 1
    @subscription_tag = current_user.subscription_tags.build(subscription_tag_params)
    @subscription_tag.position = next_position

    if @subscription_tag.save
      respond_to do |format|
        format.html { redirect_to my_subscriptions_path, notice: "Tag created." }
        format.turbo_stream
      end
    else
      redirect_to my_subscriptions_path, alert: @subscription_tag.errors.full_messages.join(", ")
    end
  end

  def update
    @subscription_tag = current_user.subscription_tags.find(params[:id])

    if @subscription_tag.update(subscription_tag_params)
      respond_to do |format|
        format.html { redirect_to my_subscriptions_path, notice: "Tag updated." }
        format.turbo_stream
      end
    else
      redirect_to my_subscriptions_path, alert: @subscription_tag.errors.full_messages.join(", ")
    end
  end

  def destroy
    @subscription_tag = current_user.subscription_tags.find(params[:id])
    @subscription_tag.destroy

    respond_to do |format|
      format.html { redirect_to my_subscriptions_path, notice: "Tag deleted." }
      format.turbo_stream
    end
  end

  def reorder
    params[:subscription_tag_ids].each_with_index do |id, index|
      current_user.subscription_tags.find(id).update(position: index)
    end

    head :ok
  end

  private

  def subscription_tag_params
    params.require(:subscription_tag).permit(:name)
  end
end
