atom_feed do |feed|
  feed.id("rururu/feeds/channel_groups")
  feed.title("New Channel Groups")
  feed.updated(@channel_groups.maximum(:created_at))

  @channel_groups.each do |channel_group|
    feed.entry(channel_group, url: channel_group_path(channel_group)) do |entry|
      entry.id("rururu/channel_group/#{channel_group.id}")
      entry.title(channel_group.name)
      entry.link(channel_group_path(channel_group))
      entry.published(channel_group.created_at)
      entry.summary("#{channel_group.channels.count} channels") if channel_group.channels.any?
    end
  end
end
