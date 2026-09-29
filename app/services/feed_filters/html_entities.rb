module FeedFilters
  # WHATWG の名前付き文字参照 (HTML のエンティティ) の表。Rust の fetcher も同じ JSON を読む。
  module HtmlEntities
    TABLE = JSON.parse(File.read(File.expand_path("data/html_entities.json", __dir__))).freeze
  end
end
