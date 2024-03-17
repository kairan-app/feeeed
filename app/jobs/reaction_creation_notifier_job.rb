class ReactionCreationNotifierJob < ApplicationJob
  def perform(reaction_id)
    webhook_url = ENV["DISCORD_WEBHOOK_URL"]
    return if webhook_url.nil?

    reaction = Reaction.find(reaction_id)
    user = reaction.user

    content = "@#{user.name} pawed!"
    embeds = [reaction.to_embed]
  
    Faraday.post(
      webhook_url, { content: "[#{Rails.env}] #{content}", embeds: }.to_json, "Content-Type" => "application/json"
    )
  end
end
