atom_feed do |feed|
  feed.id("rururu/@#{@user.name}/pawprints")
  feed.title("Pawprints of @#{@user.name}")
  feed.updated(@pawprints.maximum(:created_at))

  @pawprints.each do |pawprint|
    feed.entry(pawprint, url: pawprint.item.url) do |entry|
      entry.id("rururu/pawprint/#{pawprint.id}")
      entry.title(pawprint.item.title)
      entry.link(pawprint.item.url)
      entry.published(pawprint.item.published_at)
      entry.summary("💬 " + pawprint.memo) if pawprint.memo.present?
    end
  end
end
