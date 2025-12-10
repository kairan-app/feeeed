atom_feed do |feed|
  feed.id("rururu/releases")
  feed.title("rururuのリリース情報")
  feed.subtitle("rururuの機能の追加や変更についてお知らせします")
  feed.updated(@releases.first ? Time.zone.parse(@releases.first["published_at"]) : Time.current)

  @releases.each do |release|
    feed.entry(release, url: release["html_url"], id: "rururu/release/#{release['id']}") do |entry|
      entry.title(release["name"].presence || release["tag_name"])
      entry.link(href: release["html_url"])
      entry.published(Time.zone.parse(release["published_at"]))
      entry.updated(Time.zone.parse(release["published_at"]))
      entry.author { |author| author.name(release.dig("author", "login")) }
      entry.content(release["body"], type: "text") if release["body"].present?
    end
  end
end
