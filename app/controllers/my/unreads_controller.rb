class My::UnreadsController < MyController
  def show
    mode = (params[:mode].in?(%w[text audio video]) ? params[:mode] : nil)&.to_sym
    @range_days = (params[:range_days].presence || session[:range_days] || 3).to_i
    @channel_and_items = current_user.unread_items_grouped_by_channel(range_days: @range_days, mode: mode)

    session[:range_days] = @range_days

    @title = "Unreads"
  end
end
