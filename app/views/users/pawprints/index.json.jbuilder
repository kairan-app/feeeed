json.count @pawprints.count
json.pawprints @pawprints do |pawprint|
  json.id pawprint.id
  json.created_at pawprint.created_at
  json.memo pawprint.memo
  json.item do
    json.title pawprint.item.title
    json.url pawprint.item.url
    json.image_url pawprint.item.image_url
  end
end
