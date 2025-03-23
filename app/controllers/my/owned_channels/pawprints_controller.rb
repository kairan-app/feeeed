class My::OwnedChannels::PawprintsController < MyController
  def index
    @pawprints = Pawprint
      .joins(item: :channel)
      .joins("INNER JOIN ownerships ON ownerships.channel_id = channels.id")
      .where(ownerships: { user_id: current_user.id })
      .eager_load(:user, :item)
      .order(id: :desc)
      .page(params[:page])

    @title = "Pawprints to Your Items"
  end
end
