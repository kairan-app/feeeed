json.count @pawprints.count
json.pawprints @pawprints do |pawprint|
  json.id pawprint.id
  json.created_at pawprint.created_at
  json.memo pawprint.memo
  json.item do
    json.title pawprint.item.title
    json.url pawprint.item.url
    json.image_url pawprint.item.image_url
    json.channel do
      json.id pawprint.item.channel.id
      json.title pawprint.item.channel.title
      json.feed_url pawprint.item.channel.feed_url
      json.site_url pawprint.item.channel.site_url
      json.image_url pawprint.item.channel.image_url
    end
  end
end
