class My::UnreadsController < MyController
  def show
    @days_before = (params[:days_before].presence || 3).to_i
    @channel_and_items =
      current_user.subscribed_items.
      preload(:channel).
      where("NOT EXISTS (SELECT 1 FROM pawprints WHERE pawprints.item_id = items.id AND pawprints.user_id = ?)", current_user.id).
      where("items.created_at > ?", @days_before.days.ago).
      group_by(&:channel).
      sort_by { |_, items| items.map(&:created_at).max }.
      reverse

    @title = "Unreads"
  end
end
