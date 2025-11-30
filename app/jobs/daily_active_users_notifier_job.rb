class DailyActiveUsersNotifierJob < ApplicationJob
  queue_as :default

  def perform(target_date: Date.yesterday)
    event_counts = Ahoy::Event
      .where(time: target_date.all_day)
      .where.not(user_id: nil)
      .group(:user_id)
      .count

    return if event_counts.empty?

    user_names = User.where(id: event_counts.keys).pluck(:id, :name).to_h

    sorted_counts = event_counts.sort_by { |_, count| -count }
    max_digits = sorted_counts.first.last.to_s.length

    lines = sorted_counts.map { |user_id, count|
      format("%#{max_digits}d events : %s", count, user_names[user_id])
    }

    content = [
      "📊 Daily Active Users (#{target_date.strftime('%Y-%m-%d')})",
      "```",
      *lines,
      "```"
    ].join("\n")

    DiscoPosterJob.perform_later(content: content, channel: :admin)
  end
end
