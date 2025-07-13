class WelcomeController < ApplicationController
  def index
    @pawprints = Pawprint.recent_with_associations.limit(12)
    @channel_groups = ChannelGroup.recent_with_associations.limit(12)
    @channel_and_items = Channel.with_recent_items
    @channels = Channel.recent.limit(12)

    @title = "Enjoy feeds!"
  end
end
