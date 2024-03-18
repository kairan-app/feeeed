class PawprintCreationNotifierJob < ApplicationJob
  def perform(pawprint_id)
    webhook_url = ENV["DISCORD_WEBHOOK_URL"]
    return if webhook_url.nil?

    pawprint = Pawprint.find(pawprint_id)
    user = pawprint.user

    content = "@#{user.name} pawed!"
    embeds = [pawprint.to_embed]
  
    Faraday.post(
      webhook_url, { content: "[#{Rails.env}] #{content}", embeds: }.to_json, "Content-Type" => "application/json"
    )
  end
end
