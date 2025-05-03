atom_feed do |feed|
  feed.id("rururu/feeds/channels")
  feed.title("rururu Recent Channels")
  feed.updated(@channels.maximum(:created_at))

  @channels.each do |channel|
    feed.entry(channel, url: channel_path(channel)) do |entry|
      entry.id("rururu/channel/#{channel.id}")
      entry.title(channel.title)
      entry.link(channel_path(channel))
      entry.published(channel.created_at)
      entry.summary(channel.description) if channel.description.present?
    end
  end
end
