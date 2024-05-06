class Channels::PreviewController < ApplicationController
  before_action :login_required

  def show
    url = params[:url]
    @channel = Channel.preview(url)
    return redirect_to(root_path, alert: "Can't find feed from '#{url}'") if @channel.nil?

    @similar_channels = Channel.similar_to(@channel)

    @title = "Channel Preview: #{@channel.title}"
  end
end
