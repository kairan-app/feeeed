json.count @subscribed_items.count
json.subscribed_items @subscribed_items do |item|
  json.id item.id
  json.title item.title
  json.url item.url
  json.published_at item.published_at
  json.channel do
    json.id item.channel.id
    json.title item.channel.title
    json.feed_url item.channel.feed_url
    json.site_url item.channel.site_url
  end
end
