require "test_helper"

# fetcher (Rust) が送る result のサンプル (fetcher/testdata/result/*.json) を FetchResultApplier に通し、
# Rails の取り込み処理で作った golden (fetcher/testdata/fixtures/*.golden.json) と同じ item ができることを確かめる。
# Rust 側は fetcher/tests/result_samples.rs が、自分の出力とサンプルが一致することを確かめる
class FetchResultContractTest < ActiveSupport::TestCase
  RESULT_DIR = Rails.root.join("fetcher/testdata/result")
  FIXTURE_DIR = Rails.root.join("fetcher/testdata/fixtures")

  setup do
    Sentry.stubs(:capture_message)
    Sentry.stubs(:capture_exception)
  end

  RESULT_DIR.glob("*.json").each do |path|
    name = path.basename(".json").to_s

    test "#{name} のサンプルから golden どおりの item ができる" do
      payload = JSON.parse(path.read)
      golden = JSON.parse(FIXTURE_DIR.join("#{name}.golden.json").read)
      url_path = FIXTURE_DIR.join("#{name}.url")
      feed_url = url_path.exist? ? url_path.read.lines.first.strip : "https://example.com/#{name}/feed.xml"
      channel = Channel.create!(title: "Before", feed_url:)

      applier = FetchResultApplier.new(channel:)
      assert applier.apply_channel!(payload)
      applier.save_items!(payload["entries"], latest_guids: payload["latest_guids"])

      expected = golden["entries"].map { |e|
        e.slice("guid", "title", "url", "image_url", "published_at").merge("data" => e["data"].compact)
      }
      actual = channel.items.order(:published_at, :guid).map { |item|
        { "guid" => item.guid, "title" => item.title, "url" => item.url, "image_url" => item.image_url,
          "published_at" => item.published_at.utc.iso8601,
          "data" => FetcherGolden::DATA_KEYS.index_with { item.data&.dig(_1)&.to_s }.compact }
      }
      assert_equal expected.sort_by { [ _1["published_at"], _1["guid"] ] }, actual

      if golden["channel"]
        channel.reload
        assert_equal golden["channel"].slice("title", "description", "site_url", "image_url"),
                     { "title" => channel.title, "description" => channel.description,
                       "site_url" => channel.site_url, "image_url" => channel.image_url }
      end
    end
  end
end
