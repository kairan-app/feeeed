class My::UnreadsController < MyController
  def show
    @range_days = (params[:range_days].presence || session[:range_days] || 3).to_i
    session[:range_days] = @range_days

    @channel_and_items =
      current_user.subscribed_items.
      preload(:channel).
      where("NOT EXISTS (SELECT 1 FROM pawprints WHERE pawprints.item_id = items.id AND pawprints.user_id = ?)", current_user.id).
      where("NOT EXISTS (SELECT 1 FROM item_skips WHERE item_skips.item_id = items.id AND item_skips.user_id = ?)", current_user.id).
      where("items.created_at > ?", @range_days.days.ago).
      group_by(&:channel).
      sort_by { |_, items| items.map(&:created_at).max }.
      reverse

    @title = "Unreads"
  end
end
