atom_feed do |feed|
  feed.id("rururu/@#{@user.name}/subscribed_items")
  feed.title("Subscribed items of @#{@user.name}")
  feed.updated(@subscribed_items.maximum(:created_at))

  @subscribed_items.each do |item|
    feed.entry(item, url: item.url) do |entry|
      entry.id("rururu/item/#{item.id}")
      entry.title(item.title)
      entry.link(item.url)
      entry.published(item.published_at)
      entry.summary(item.channel.title)
    end
  end
end
