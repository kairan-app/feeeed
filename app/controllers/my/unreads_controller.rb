class My::UnreadsController < MyController
  def show
    @range_days = (params[:range_days].presence || session[:range_days] || 3).to_i
    @mode = params[:mode].in?(%w[text audio video]) ? params[:mode].to_sym : nil
    @channel_group = ChannelGroup.find_by(id: params[:channel_group_id])
    @channel_groups = current_user.channel_groups.order(id: :desc)
    @channel_and_items = current_user.unread_items_grouped_by_channel(
      range_days: @range_days, mode: @mode, channel_group: @channel_group
    )
    @unreads_params = {
      range_days: @range_days,
      mode: @mode,
      channel_group_id: @channel_group&.id
    }

    session[:range_days] = @range_days

    @title = "Unreads"
    @title += " #{@mode}s" if @mode
  end
end
