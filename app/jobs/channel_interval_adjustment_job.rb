class ChannelIntervalAdjustmentJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info "Starting channel interval adjustment..."
    updated_count = Channel.adjust_all_check_intervals
    Rails.logger.info "Channel interval adjustment completed. Updated #{updated_count} channels."
  end
end
