class ChannelScheduleAdjustmentJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info "Starting channel schedule adjustment..."
    result = Channel.adjust_all_schedules!
    Rails.logger.info "Channel schedule adjustment completed:"
    Rails.logger.info "  Added: #{result[:added]} schedules"
    Rails.logger.info "  Removed: #{result[:removed]} schedules"
    Rails.logger.info "  Skipped: #{result[:skipped_insufficient]} (insufficient items)"
    Rails.logger.info "  Skipped: #{result[:skipped_inactive]} (inactive > 1 month)"
  end
end
