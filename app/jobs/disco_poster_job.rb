class DiscoPosterJob < ApplicationJob
  queue_as :disco

  def perform(content: nil, embeds: nil, channel: :default)
    sleep 1
    Disco.post({ content:, embeds: }, channel:)
  end
end
