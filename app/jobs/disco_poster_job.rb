class DiscoPosterJob < ApplicationJob
  queue_as :disco

  def perform(content: nil, embeds: nil)
    sleep 1
    Disco.post({ content:, embeds: })
  end
end
