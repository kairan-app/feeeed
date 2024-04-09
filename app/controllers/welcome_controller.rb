class WelcomeController < ApplicationController
  def index
    @channels = Channel.includes(:items).limit(10)
    @channel_and_items_for_welcome = @channels.map do |channel|
      [channel, channel.items.order(created_at: :desc).limit(3)]
    end.sort_by { |channel, items| items.first&.created_at }.reverse.to_h
    @pawprints = Pawprint.order(id: :desc).limit(30)

    @title = "Feed Network"
  end
end
