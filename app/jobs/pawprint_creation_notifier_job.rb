class PawprintCreationNotifierJob < ApplicationJob
  def perform(pawprint_id)
    pawprint = Pawprint.find(pawprint_id)
    user = pawprint.user

    content = "@#{user.name} pawed!"
    embeds = [pawprint.to_embed]

    Disco.post({ content: "[#{Rails.env}] #{content}", embeds: })
  end
end
