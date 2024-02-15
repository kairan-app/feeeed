class My::InboxController < MyController
  def show
    @items = current_user.subscribed_items.preload(:channel).order("items.published_at DESC").page(params[:page])

    @title = "Inbox"
  end
end
