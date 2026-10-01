# 保存済みの、URL になっていない Item#image_url を直す (#830)。
# 先頭に U+FFFC や改行が付いたものは URL の部分だけにし、/ で始まる相対パスは Item の URL を基準に絶対 URL にする。
# どちらにもならないものは nil にする。lib/tasks/items.rake から使う。
class ItemImageUrlRepairer
  def self.targets
    Item.where.not(image_url: [ nil, "" ]).where("image_url !~ ?", "^(https?:)?//")
  end

  def self.repaired_image_url(item)
    normalized = Item.normalize_image_url(item.image_url)
    return normalized if normalized
    return nil unless item.image_url.start_with?("/")

    joined = Addressable::URI.parse(item.url).join(item.image_url).to_s
    joined if joined.match?(Item::DISPLAYABLE_IMAGE_URL)
  rescue Addressable::URI::InvalidURIError
    nil
  end

  def self.run(apply:, io: $stdout)
    count = 0

    targets.find_each do |item|
      repaired = repaired_image_url(item)
      io.puts "item #{item.id} (channel #{item.channel_id}): #{item.image_url.inspect} -> #{repaired.inspect}"
      # validation・callback・updated_at の更新は要らないので update_column を使う
      item.update_column(:image_url, repaired) if apply
      count += 1
    end

    io.puts(apply ? "repaired #{count} items" : "dry run: #{count} items would be repaired (set APPLY=1 to write)")
  end
end
