class My::UnreadsController < MyController
  def show
    @range_days = (params[:range_days].presence || session[:range_days] || 3).to_i
    @item_summary_line_clamp = (params[:item_summary_line_clamp].presence || session[:item_summary_line_clamp] || 4).to_i

    @channel_group = ChannelGroup.find_by(id: params[:channel_group_id])
    @channel_groups = current_user.own_and_joined_channel_groups.order(id: :desc)
    @channel_and_items = current_user.unread_items_grouped_by_channel(
      range_days: @range_days, channel_group: @channel_group
    )
    @unreads_params = {
      range_days: @range_days,
      channel_group_id: @channel_group&.id
    }

    session[:range_days] = @range_days
    session[:item_summary_line_clamp] = @item_summary_line_clamp

    @title = "Unreads"
  end
end
