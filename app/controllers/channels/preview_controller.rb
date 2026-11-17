class Channels::PreviewController < ApplicationController
  before_action :login_required

  # 相手のサイトの状態や URL の形で起きる取得の失敗。利用者に知らせてトップに戻し、Sentry には送らない
  FETCH_ERRORS = [
    *Httpc::EXTERNAL_ERRORS,
    Faraday::Error,
    URI::InvalidURIError
  ].freeze

  def show
    input = params[:url].to_s.strip
    return redirect_to(root_path, alert: "Please enter a URL") if input.blank?

    url = normalize_url(input)
    return redirect_to(root_path, alert: "'#{input}' is not a valid URL") if url.nil?

    begin
      @channel = Channel.preview(url)
    rescue Feedjira::NoParserAvailable
      return redirect_to(root_path, alert: "Can't find feed from '#{url}'")
    rescue *FETCH_ERRORS => e
      Rails.logger.info "[Channels::PreviewController] Failed to fetch #{url}: #{e.class}: #{e.message}"
      return redirect_to(root_path, alert: "Couldn't fetch a feed from '#{url}'")
    end

    return redirect_to(root_path, alert: "Can't find feed from '#{url}'") if @channel.nil?

    @similar_channels = Channel.similar_to(@channel)

    DiscoPosterJob.perform_later(content: "@#{current_user.name} previewed #{@channel.title}\n#{@channel.feed_url}", channel: :user_activities)
    @title = "Channel Preview: #{@channel.title}"
  end

  private

  # スキームが無ければ https:// を補う。http/https の URL として読めなければ nil を返す
  def normalize_url(input)
    url = input.match?(%r{\A[a-z][a-z0-9+.-]*://}i) ? input : "https://#{input}"
    uri = URI.parse(url)
    return nil unless uri.is_a?(URI::HTTP) && uri.host.present?

    url
  rescue URI::InvalidURIError
    nil
  end
end
