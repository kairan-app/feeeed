class WelcomeController < ApplicationController
  def index
    @pawprints =
      Pawprint.
        includes(:user, item: :channel).
        order(id: :desc).
        limit(12)

    @channel_groups =
      ChannelGroup.
        includes(:channels).
        order(id: :desc).
        limit(12)

    @channel_and_items =
      Channel.
        joins(:items).
        select("channels.*, MAX(items.id) AS max_item_id").
        group("channels.id").
        order("max_item_id DESC").
        limit(12)

    # 各channelの最新3件のアイテムを効率的に取得
    channel_ids = @channel_and_items.map(&:id)
    items_by_channel = Item.
      where(channel_id: channel_ids).
      order(id: :desc).
      group_by(&:channel_id)

    # 各channelに最新アイテムを動的にセット
    @channel_and_items.each do |channel|
      channel.define_singleton_method(:recent_items) do
        @recent_items ||= (items_by_channel[id] || []).first(3)
      end
    end

    @channels =
      Channel.
        order(id: :desc).
        limit(12)

    @title = "Enjoy feeds!"
  end
end
