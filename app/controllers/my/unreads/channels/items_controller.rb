class My::Unreads::Channels::ItemsController < MyController
  def index
    @channel = Channel.find(params[:channel_id])
    @offset = params[:offset].to_i
    @limit = params[:limit].presence&.to_i || 3
    @range_days = params[:range_days].to_i
    @item_summary_line_clamp = session[:item_summary_line_clamp] || 4

    items_with_check = current_user.unread_items_for(
      @channel,
      offset: @offset,
      limit: @limit + 1,
      range_days: @range_days
    )

    @items = items_with_check.take(@limit)
    @next_offset = @offset + @limit
    @has_more = items_with_check.size > @limit

    respond_to do |format|
      format.turbo_stream
    end
  end
end
