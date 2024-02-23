class ReactionCreationNotifierJob < ApplicationJob
  def perform(reaction_id)
    webhook_url = ENV["DISCORD_WEBHOOK_URL"]
    return if webhook_url.nil?

    reaction = Reaction.find(reaction_id)
    user = reaction.user
    item = reaction.item

    content = ["@#{user.name} reacted to #{item.url}", reaction.memo].compact.join("\n")
  
    Faraday.post(
      webhook_url, {
        content: "[#{Rails.env}]\n#{content}"
      }.to_json,
      "Content-Type" => "application/json"
    )
  end
end
