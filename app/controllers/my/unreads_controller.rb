class My::UnreadsController < MyController
  def show
    @range_days = (params[:range_days].presence || session[:range_days] || 3).to_i
    @item_summary_line_clamp = (params[:item_summary_line_clamp].presence || session[:item_summary_line_clamp] || 4).to_i

    @channel_group = ChannelGroup.find_by(id: params[:channel_group_id])
    @channel_groups = current_user.own_and_joined_channel_groups.order(id: :desc)

    initial_days = 1
    @channel_and_items = current_user.unread_items_grouped_by_channel(
      range_days: initial_days, channel_group: @channel_group
    )
    @unreads_params = {
      range_days: @range_days,
      channel_group_id: @channel_group&.id
    }

    session[:range_days] = @range_days
    session[:item_summary_line_clamp] = @item_summary_line_clamp

    @title = "Unreads"
  end

  def load_more
    @current_days = params[:current_days].to_i
    @channel_group = ChannelGroup.find_by(id: params[:channel_group_id])

    @channel_and_items = current_user.unread_items_grouped_by_channel_for_date_range(
      from_days_ago: @current_days,
      to_days_ago: @current_days + 1,
      channel_group: @channel_group
    )

    @item_summary_line_clamp = session[:item_summary_line_clamp] || 4
    @next_days = @current_days + 1

    render json: {
      html: render_to_string(partial: 'channel_items', locals: {
        channel_and_items: @channel_and_items,
        item_summary_line_clamp: @item_summary_line_clamp
      }),
      next_days: @next_days,
      has_more: @channel_and_items.any?
    }
  end
end
