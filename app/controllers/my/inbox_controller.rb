class My::InboxController < MyController
  def show
    @items = current_user.subscribed_items.preload(:channel).order(published_at: :desc, title: :desc).page(params[:page])

    @title = "Inbox"
  end
end
