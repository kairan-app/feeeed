class ReactionCreationNotifierJob < ApplicationJob
  def perform(reaction_id)
    webhook_url = ENV["DISCORD_WEBHOOK_URL"]
    return if webhook_url.nil?

    reaction = Reaction.find(reaction_id)
    user = reaction.user
    item = reaction.item

    content = "@#{user.name} pawed!"
    embeds = [
      {
        title: [item.title, item.channel.title].join(" | "),
        description: reaction.memo.present? ? "💬 #{reaction.memo}" : nil,
        url: item.url,
        thumbnail: { url: item.image_url_or_placeholder },
      }
    ]
  
    Faraday.post(
      webhook_url, { content: "[#{Rails.env}] #{content}", embeds: }.to_json, "Content-Type" => "application/json"
    )
  end
end
