class JoinRequestNotifierJob < ApplicationJob
  queue_as :default

  def perform(join_request)
    embeds = [
      {
        title: "🔔 新しいJoin Requestがありました",
        color: 3447003, # Blue color
        fields: [
          {
            name: "Email",
            value: join_request.email,
            inline: true
          },
          {
            name: "コメント",
            value: join_request.comment.presence || "（なし）",
            inline: false
          }
        ],
        timestamp: Time.current.iso8601
      }
    ]

    DiscoPosterJob.perform_later(embeds: embeds, channel: :admin)
  end
end
