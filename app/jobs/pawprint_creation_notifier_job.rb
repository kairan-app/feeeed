class PawprintCreationNotifierJob < ApplicationJob
  queue_as :disco

  def perform(pawprint_id)
    # 足あとを付けてすぐ外すと、ジョブが動くころにはもう消えている。外した足あとは通知しなくてよい
    pawprint = Pawprint.find_by(id: pawprint_id)
    return if pawprint.nil?

    user = pawprint.user

    content = "@#{user.name} pawed!"
    embeds = [ pawprint.to_discord_embed ]

    DiscoPosterJob.perform_later(content:, embeds:, channel: :user_activities)
  end
end
