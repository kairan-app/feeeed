class ChannelItemsFetcherJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info "Starting hourly channel fetch at #{Time.current}"
    Channel.fetch_and_save_items
  end
end
