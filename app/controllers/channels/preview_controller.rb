class Channels::PreviewController < ApplicationController
  before_action :login_required

  def show
    url = params[:url].to_s.strip
    return redirect_to(root_path, alert: "Please enter a URL") if url.blank?

    begin
      @channel = Channel.preview(url)
    rescue Feedjira::NoParserAvailable
      return redirect_to(root_path, alert: "Can't find feed from '#{url}'")
    end

    return redirect_to(root_path, alert: "Can't find feed from '#{url}'") if @channel.nil?

    @similar_channels = Channel.similar_to(@channel)

    DiscoPosterJob.perform_later(content: "@#{current_user.name} previewed #{@channel.title}\n#{@channel.feed_url}", channel: :user_activities)
    @title = "Channel Preview: #{@channel.title}"
  end
end
