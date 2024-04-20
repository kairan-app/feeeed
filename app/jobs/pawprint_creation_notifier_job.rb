class PawprintCreationNotifierJob < ApplicationJob
  def perform(pawprint_id)
    pawprint = Pawprint.find(pawprint_id)
    user = pawprint.user

    content = "@#{user.name} pawed!"
    embeds = [pawprint.to_discord_embed]

    DiscoPosterJob.perform_later(content:, embeds:)
  end
end
