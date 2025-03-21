class My::OwnedChannels::PawprintsController < MyController
  def index
    @pawprints = Pawprint
      .joins(item: :channel)
      .joins("INNER JOIN ownerships ON ownerships.channel_id = channels.id")
      .where(ownerships: { user: current_user })
      .eager_load(:user, :item)
      .order(id: :desc)
      .page(params[:page])

    @title = "Owned Channels Pawprints"
  end
end