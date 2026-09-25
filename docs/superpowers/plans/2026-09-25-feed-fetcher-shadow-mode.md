# フィード fetcher 影モード 実装計画 (計画1/2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rust 製 fetcher と Cloudflare Workers 製 dispatcher を作り、本番 DB に一切書き込まずに「Rust のパース結果が Rails の取り込み結果と一致するか」を本番フィードで検証できる状態 (影モード) にする。

**Architecture:** Rails 側に「Rails の取り込み処理が保存する結果」を JSON で書き出す golden 生成器を作り、それを正解として Rust の fetcher をテスト駆動で作る。fetcher は Feedjira (sax-machine) の要素マッピング規則を Rust で再現する小さなエンジンを持つ。dispatcher は読み取り専用の API (影モード用の選定・新規判定・保存済み item の参照) だけを提供し、fetcher の `shadow` コマンドが本番の保存済みデータと突き合わせてレポートを出す。

**Tech Stack:** Rust (tokio, reqwest, quick-xml, chrono, regex, url, scraper, html-escape, clap, serde, wiremock), TypeScript (Hono, postgres.js, vitest, wrangler), Cloudflare Workers + Hyperdrive, Rails 8 (Minitest)

**Spec:** `docs/superpowers/specs/2026-09-25-feed-fetcher-offload-design.md`

**この計画の範囲:** spec の節8「移行手順」の 1 (影モード) まで。`channel_leases`、`POST /leases`、`POST /leases/:id/result`、Rails 側のロールアウト制御、Puma 内 Solid Queue 化は計画2で扱う。影モードの結果 (どこが一致しないか) を見てから計画2を書く。

## Global Constraints

- DB への変更は追加のみ。この計画ではスキーマ変更をしない
- dispatcher は本番 DB に書き込まない (この計画のエンドポイントはすべて読み取り専用)
- ワーカー名はマシンごと。認証は `Authorization: Bearer <token>`、dispatcher 側は「ワーカー名 → トークンの SHA-256 (16進小文字)」の JSON を secret `WORKER_TOKENS` に持つ
- fetcher の既定 User-Agent は `Faraday v2.14.3` (現行 Rails と同じ)。設定で変更可能にする
- HTTP のタイムアウト: 接続 10秒、全体 30秒。リダイレクトは最大3回 (Faraday の follow_redirects の既定と同じ)
- 同じホストへは同時に1本まで、前回アクセスから最低1秒空ける (フィード取得と OGP 取得の両方)
- フィルタ名は Ruby のクラス名 (demodulize 後) と同じ文字列: `HtmlEntityFixer`、`AtomNamespaceFixer`、`RelativeUrlResolver`
- `items.data` に入れるキーは `entry_id`、`title`、`url`、`published`、`summary`、`itunes_subtitle`、`enclosure_url`、`enclosure_type` の8つ
- dispatcher の `wrangler.toml` には `[observability] enabled = true` を入れる
- リポジトリは public。第三者のフィード本文をコミットしない (本番フィードを使う比較用コーパスは gitignore 下に置く)
- Ruby を触ったら `docker compose run --rm web bundle exec rubocop -c .rubocop.yml` を通す
- Rails のコマンドは `docker compose run --rm web ...` で実行する

## Review Focus

- **定義されていない HTML エンティティ** (`&nbsp;` など) が copyright/generator 以外の要素 (item の description など) に入っているフィード: フィード全体が失敗せず、Rails と同じ結果になるべき → Task 2 のフィクスチャ `rss_edge.xml` に入れて golden で固定する
- **UTF-8 として不正なバイト列を含むフィード**: 落ちずに不正バイトだけ取り除いてパースを続けるべき → Task 2 のフィクスチャ `rss_invalid_utf8.xml` と Task 3 の単体テスト
- **応答が返ってこない・極端に遅いサーバ**: 30秒で打ち切ってエラーとして扱い、他のチャンネルの処理を止めないべき → Task 7 のタイムアウトのテスト
- **リダイレクトのループや4回以上のリダイレクト**: エラーとして扱うべき (Rails も `RedirectLimitReached` で失敗する) → Task 7 のテスト
- **同じホストのチャンネルが1回の影モードの実行に大量に含まれる** (YouTube 268件など): 同時アクセスせず、1秒以上間隔を空けて順番に処理するべき → Task 7 の HostGate の並行テストと Task 10 の選定クエリのテスト

---

## ファイル構成

```
lib/fetcher_golden.rb                      # Rails: golden 生成器 (Task 1)
lib/tasks/fetcher.rake                     # Rails: golden 生成の rake タスク (Task 1)
test/lib/fetcher_golden_test.rb            # Rails: golden 生成器のテスト (Task 1)

fetcher/                                   # Rust クレート (Task 2〜9, 11, 12)
  Cargo.toml
  src/main.rs                              # CLI (golden-check / shadow)
  src/lib.rs
  src/model.rs                             # 出力の型 (ShapedFeed など)
  src/ruby.rs                              # Ruby 互換の小道具 (blank?, strip, URI 判定)
  src/encoding.rs                          # 不正バイトの除去
  src/filters/{mod,html_entity_fixer,atom_namespace_fixer,relative_url_resolver}.rs
  src/parse/{mod,sax,classes,detect,extract,date}.rs
  src/shape/{mod,channel,entry}.rs
  src/http/{mod,host_gate}.rs
  src/ogp.rs
  src/dispatcher_client.rs
  src/shadow.rs
  tests/golden.rs
  testdata/fixtures/*.xml, *.golden.json   # 合成フィクスチャと golden (コミットする)
  testdata/corpus/                         # 本番フィードのコーパス (gitignore)
  scripts/collect_corpus.sh

dispatcher/                                # Cloudflare Worker (Task 9, 10)
  package.json, tsconfig.json, wrangler.toml, vitest.config.ts
  src/index.ts, src/app.ts, src/auth.ts, src/db.ts, src/queries.ts
  test/helpers.ts, test/auth.test.ts, test/queries.test.ts, test/app.test.ts

docker-compose.yml                         # dispatcher のテスト用サービスを追加 (Task 9)
.github/workflows/ci.yml                   # fetcher / dispatcher のテストを追加 (Task 12)
.gitignore                                 # target, node_modules, corpus など (Task 2, 9)
```

---

### Task 1: Rails 側の golden 生成器

Rails の本物の取り込み処理 (`Channel.fetch_and_normalize_feed` → `Channel.build_from` → `Channel#save` → `Channel#fetch_and_save_items(:all)`) にフィードの本文を通して、保存される結果を JSON にする。HTTP (フィード取得・OGP) と Sentry と `sleep` は一時的に差し替え、DB への変更はトランザクションでロールバックする。

**Files:**
- Create: `lib/fetcher_golden.rb`
- Create: `lib/tasks/fetcher.rake`
- Test: `test/lib/fetcher_golden_test.rb`

**Interfaces:**
- Produces: `FetcherGolden.build(body: String, feed_url: String) -> Hash` (キーは Symbol。JSON にすると次の形)

```json
{
  "format": "rss",
  "channel": { "title": "...", "description": "...", "site_url": "...", "image_url": null },
  "applied_filters": ["RelativeUrlResolver"],
  "entries": [
    { "guid": "...", "title": "...", "url": "...", "image_url": null,
      "published_at": "2026-09-24T01:00:00Z",
      "data": { "summary": "...", "itunes_subtitle": null, "enclosure_url": null, "enclosure_type": null } }
  ],
  "skipped": [ { "title": "...", "reason": "no_url" } ]
}
```

- `format`: `itunes_rss` / `rss_feedburner` / `google_docs_atom` / `atom_youtube` / `atom_feedburner` / `atom_google_alerts` / `atom` / `rss` / `json_feed`
- `channel`: `Channel.build_from` が nil (未対応の形式) か、Channel のバリデーションに通らなければ null
- `entries`: `(published_at, guid)` の昇順
- `skipped`: `(reason, title)` の昇順。`reason` は `no_url` / `no_guid` / `validation_failed`
- rake: `rails "fetcher:golden[DIR]"` は `DIR/*.xml` それぞれについて `DIR/<name>.golden.json` を書く。feed_url は `https://example.com/<name>/feed.xml`。`DIR/<name>.url` があればその1行目を feed_url にする

- [ ] **Step 1: 失敗するテストを書く**

`test/lib/fetcher_golden_test.rb`:

```ruby
require "test_helper"

class FetcherGoldenTest < ActiveSupport::TestCase
  FEED_URL = "https://example.com/golden/feed.xml"

  RSS = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>  Golden Feed  </title>
        <link>https://example.com/</link>
        <description>desc</description>
        <item>
          <title>Second</title>
          <link>https://example.com/2</link>
          <guid isPermaLink="false">g2</guid>
          <pubDate>Wed, 24 Sep 2026 11:00:00 +0900</pubDate>
          <description>summary 2</description>
        </item>
        <item>
          <title>First</title>
          <link>https://example.com/1</link>
          <guid isPermaLink="false">g1</guid>
          <pubDate>Wed, 24 Sep 2026 10:00:00 +0900</pubDate>
        </item>
        <item>
          <title>No date</title>
          <link>https://example.com/3</link>
          <guid isPermaLink="false">g3</guid>
        </item>
      </channel>
    </rss>
  XML

  test "Railsが保存する結果をJSONにできる" do
    result = FetcherGolden.build(body: RSS, feed_url: FEED_URL)

    assert_equal "rss", result[:format]
    assert_equal({ "title" => "Golden Feed", "description" => "desc", "site_url" => "https://example.com/", "image_url" => nil }, result[:channel])
    assert_equal [], result[:applied_filters]
    assert_equal %w[g1 g2], result[:entries].map { _1[:guid] }
    assert_equal "2026-09-24T02:00:00Z", result[:entries].last[:published_at]
    assert_equal "summary 2", result[:entries].last[:data]["summary"]
    assert_equal [ { title: "No date", reason: "validation_failed" } ], result[:skipped]
  end

  test "DBに何も残さない" do
    assert_no_difference -> { Channel.count } do
      assert_no_difference -> { Item.count } do
        FetcherGolden.build(body: RSS, feed_url: FEED_URL)
      end
    end
  end

  test "差し替えたメソッドを元に戻す" do
    original = Httpc.method(:get_with_redirect_info)
    FetcherGolden.build(body: RSS, feed_url: FEED_URL)
    assert_equal original.owner, Httpc.method(:get_with_redirect_info).owner
    assert_not Channel.method_defined?(:sleep, false)
  end
end
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `docker compose run --rm web rails test test/lib/fetcher_golden_test.rb`
Expected: FAIL (`NameError: uninitialized constant FetcherGolden`)

- [ ] **Step 3: 実装する**

`lib/fetcher_golden.rb`:

```ruby
# Rust製fetcherの正解データとして、Railsの取り込み処理が保存する結果をHashで返す。
# HTTP (フィード取得・OGP)・Sentry・sleepを一時的に差し替え、DBへの変更はロールバックする。
class FetcherGolden
  FORMATS = {
    "Feedjira::Parser::ITunesRSS" => "itunes_rss",
    "Feedjira::Parser::RSSFeedBurner" => "rss_feedburner",
    "Feedjira::Parser::GoogleDocsAtom" => "google_docs_atom",
    "Feedjira::Parser::AtomYoutube" => "atom_youtube",
    "Feedjira::Parser::AtomFeedBurner" => "atom_feedburner",
    "Feedjira::Parser::AtomGoogleAlerts" => "atom_google_alerts",
    "Feedjira::Parser::Atom" => "atom",
    "Feedjira::Parser::RSS" => "rss",
    "Feedjira::Parser::JSONFeed" => "json_feed"
  }.freeze

  DATA_KEYS = %w[summary itunes_subtitle enclosure_url enclosure_type].freeze
  NULL_OGP = Struct.new(:image, :description).new(nil, nil)

  def self.build(body:, feed_url:)
    new(body:, feed_url:).build
  end

  def initialize(body:, feed_url:)
    @body = body
    @feed_url = feed_url
    @skipped = []
  end

  def build
    result = nil
    with_overrides do
      ActiveRecord::Base.transaction(requires_new: true) do
        result = build_in_transaction
        raise ActiveRecord::Rollback
      end
    end
    result
  end

  private

  def build_in_transaction
    normalization = Channel.fetch_and_normalize_feed(@feed_url)
    feed = normalization[:feed]
    channel, channel_meta = save_channel(feed, normalization)
    channel.fetch_and_save_items(:all)

    {
      format: FORMATS.fetch(feed.class.name),
      channel: channel_meta,
      applied_filters: normalization[:applied_filters],
      entries: channel.items.reload.map { entry_json(_1) }.sort_by { [ _1[:published_at], _1[:guid] ] },
      skipped: @skipped.sort_by { [ _1[:reason], _1[:title].to_s ] }
    }
  end

  def save_channel(feed, normalization)
    parameters = Channel.build_from(feed, @feed_url)
    if parameters
      channel = Channel.new(parameters.merge(
        feed_url: @feed_url,
        applied_filters: normalization[:applied_filters],
        filter_details: normalization[:filter_details]
      ))
      return [ channel, channel.slice(:title, :description, :site_url, :image_url) ] if channel.save
    end

    placeholder = Channel.new(feed_url: @feed_url, title: "golden placeholder")
    placeholder.save!(validate: false)
    [ placeholder, nil ]
  end

  def entry_json(item)
    {
      guid: item.guid,
      title: item.title,
      url: item.url,
      image_url: item.image_url,
      published_at: item.published_at.utc.iso8601,
      data: DATA_KEYS.index_with { item.data&.dig(_1)&.to_s }
    }
  end

  def with_overrides(&block)
    body = @body
    feed_url = @feed_url
    skipped = @skipped

    overrides = [
      [ Httpc, :get_with_redirect_info, ->(_url) { { body: body.dup, final_url: feed_url, redirected: false } } ],
      [ OpenGraph, :new, ->(_url) { NULL_OGP } ],
      [ Sentry, :capture_exception, ->(*_args, **_opts) { nil } ],
      [ Sentry, :capture_message, lambda { |_message, **opts|
        extra = opts[:extra] || {}
        skipped << { title: extra[:item_title], reason: extra[:skip_reason] } if extra[:skip_reason]
        nil
      } ]
    ]

    override_singletons(overrides) do
      Channel.define_method(:sleep) { |*| nil }
      begin
        block.call
      ensure
        Channel.remove_method(:sleep)
      end
    end
  end

  def override_singletons(overrides, &block)
    return block.call if overrides.empty?

    (target, name, impl), *rest = overrides
    original = target.method(name)
    target.define_singleton_method(name, &impl)
    begin
      override_singletons(rest, &block)
    ensure
      target.singleton_class.remove_method(name)
      target.define_singleton_method(name, original) if original.owner == target.singleton_class
    end
  end
end
```

`lib/tasks/fetcher.rake`:

```ruby
namespace :fetcher do
  desc "DIR/*.xml から Rust製fetcher用の golden (DIR/<name>.golden.json) を生成する"
  task :golden, [ :dir ] => :environment do |_task, args|
    dir = Pathname(args.fetch(:dir))
    dir.glob("*.xml").sort.each do |xml_path|
      name = xml_path.basename(".xml").to_s
      url_path = dir.join("#{name}.url")
      feed_url = url_path.exist? ? url_path.read.lines.first.strip : "https://example.com/#{name}/feed.xml"

      result = FetcherGolden.build(body: xml_path.binread, feed_url:)
      dir.join("#{name}.golden.json").write(JSON.pretty_generate(result) + "\n")
      puts "wrote #{name}.golden.json (#{result[:entries].size} entries, #{result[:skipped].size} skipped)"
    rescue StandardError => e
      puts "FAILED #{name}: #{e.class}: #{e.message}"
    end
  end
end
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `docker compose run --rm web rails test test/lib/fetcher_golden_test.rb`
Expected: PASS (3 runs)

- [ ] **Step 5: rubocop とコミット**

Run: `docker compose run --rm web bundle exec rubocop -c .rubocop.yml lib/fetcher_golden.rb lib/tasks/fetcher.rake test/lib/fetcher_golden_test.rb`
Expected: no offenses

```bash
git add lib/fetcher_golden.rb lib/tasks/fetcher.rake test/lib/fetcher_golden_test.rb
git commit -m "Rust製fetcher用のgolden生成器を追加"
```

---

### Task 2: fetcher クレートの土台・出力の型・合成フィクスチャと golden

**Files:**
- Create: `fetcher/Cargo.toml`, `fetcher/src/lib.rs`, `fetcher/src/main.rs`, `fetcher/src/model.rs`
- Create: `fetcher/testdata/fixtures/*.xml` (下記10個) と、それぞれの `*.golden.json` (Task 1 の rake で生成)
- Create: `fetcher/tests/golden.rs`
- Modify: `.gitignore`

**Interfaces:**
- Produces (`fetcher/src/model.rs`):
  - `enum FeedFormat { ItunesRss, RssFeedburner, GoogleDocsAtom, AtomYoutube, AtomFeedburner, AtomGoogleAlerts, Atom, Rss, JsonFeed }` (serde は snake_case)
  - `struct ChannelMeta { title: Option<String>, description: Option<String>, site_url: Option<String>, image_url: Option<String> }`
  - `struct EntryData { summary, itunes_subtitle, enclosure_url, enclosure_type: Option<String> }`
  - `struct ShapedEntry { guid: String, title: String, url: String, image_url: Option<String>, published_at: String, data: EntryData, #[serde(skip)] image_pending_ogp: bool }`
  - `enum SkipReason { NoUrl, NoGuid, ValidationFailed }` (snake_case)
  - `struct Skipped { title: Option<String>, reason: SkipReason }`
  - `struct ShapedFeed { format: FeedFormat, channel: Option<ChannelMeta>, applied_filters: Vec<String>, entries: Vec<ShapedEntry>, skipped: Vec<Skipped> }`
  - `ShapedFeed::normalize_order(&mut self)`: entries を `(published_at, guid)`、skipped を `(reason, title)` で並べる
- Produces (`fetcher/tests/golden.rs`): フィクスチャごとに `fetcher::golden_output(body, feed_url)` と golden を比べるテスト。`fetcher::golden_output` は Task 6 で実装するので、この Task では `unimplemented!()` の関数を置き、テストが失敗する状態でコミットせず `#[ignore]` を付けておく (Task 6 で外す)

- [ ] **Step 1: クレートを作る**

`fetcher/Cargo.toml`:

```toml
[package]
name = "feeeed-fetcher"
version = "0.1.0"
edition = "2024"

[lib]
name = "fetcher"
path = "src/lib.rs"

[[bin]]
name = "fetcher"
path = "src/main.rs"

[dependencies]
anyhow = "1"
chrono = { version = "0.4", features = ["serde"] }
clap = { version = "4", features = ["derive", "env"] }
html-escape = "0.2"
quick-xml = "0.38"
regex = "1"
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls", "json", "gzip", "deflate"] }
scraper = "0.24"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
thiserror = "2"
tokio = { version = "1", features = ["full"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
url = "2"

[dev-dependencies]
pretty_assertions = "1"
wiremock = "0.6"
```

`fetcher/src/model.rs`:

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedFormat {
    ItunesRss,
    RssFeedburner,
    GoogleDocsAtom,
    AtomYoutube,
    AtomFeedburner,
    AtomGoogleAlerts,
    Atom,
    Rss,
    JsonFeed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChannelMeta {
    pub title: Option<String>,
    pub description: Option<String>,
    pub site_url: Option<String>,
    pub image_url: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct EntryData {
    pub summary: Option<String>,
    pub itunes_subtitle: Option<String>,
    pub enclosure_url: Option<String>,
    pub enclosure_type: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShapedEntry {
    pub guid: String,
    pub title: String,
    pub url: String,
    pub image_url: Option<String>,
    /// UTC, 秒精度の RFC3339 (例: "2026-09-24T01:00:00Z")
    pub published_at: String,
    pub data: EntryData,
    /// Rails なら OGP 画像を取りに行く entry で、まだ取っていないもの (影モードの比較から image_url を外す)
    #[serde(skip)]
    pub image_pending_ogp: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkipReason {
    NoGuid,
    NoUrl,
    ValidationFailed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Skipped {
    pub title: Option<String>,
    pub reason: SkipReason,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShapedFeed {
    pub format: FeedFormat,
    pub channel: Option<ChannelMeta>,
    pub applied_filters: Vec<String>,
    pub entries: Vec<ShapedEntry>,
    pub skipped: Vec<Skipped>,
}

impl ShapedFeed {
    pub fn normalize_order(&mut self) {
        self.entries
            .sort_by(|a, b| (&a.published_at, &a.guid).cmp(&(&b.published_at, &b.guid)));
        self.skipped.sort_by(|a, b| {
            let ra = serde_json::to_string(&a.reason).unwrap();
            let rb = serde_json::to_string(&b.reason).unwrap();
            (ra, a.title.clone().unwrap_or_default()).cmp(&(rb, b.title.clone().unwrap_or_default()))
        });
    }
}
```

(skipped の並びは Ruby 側と同じく reason の文字列順にするため、enum の順序ではなく JSON の文字列で比べる。)

`fetcher/src/lib.rs`:

```rust
pub mod model;

use model::ShapedFeed;

/// フィードの本文を Rails の取り込みと同じ規則で整形する (HTTP を使わない。OGP は取らない)。
pub fn golden_output(_body: &[u8], _feed_url: &str) -> anyhow::Result<ShapedFeed> {
    unimplemented!("Task 6 で実装する")
}
```

`fetcher/src/main.rs`:

```rust
fn main() {
    println!("fetcher");
}
```

`.gitignore` の末尾に追加:

```
# fetcher / dispatcher
/fetcher/target
/fetcher/testdata/corpus/*
!/fetcher/testdata/corpus/.keep
```

`fetcher/testdata/corpus/.keep` を空ファイルで作る。

- [ ] **Step 2: 合成フィクスチャを作る**

`fetcher/testdata/fixtures/rss_basic.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:media="http://search.yahoo.com/mrss/" xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>Basic RSS</title>
    <link>https://example.com/</link>
    <description><![CDATA[<p>desc</p>]]></description>
    <image><title>ignored image title</title><url>https://example.com/logo.png</url><link>https://example.com/ignored</link></image>
    <item>
      <title>Permalink guid only</title>
      <guid>https://example.com/posts/1</guid>
      <pubDate>Mon, 22 Sep 2026 09:00:00 +0900</pubDate>
      <description><![CDATA[<p>hello <b>world</b></p>]]></description>
      <media:thumbnail url="https://example.com/1.jpg"/>
    </item>
    <item>
      <title>Non-permalink guid with link</title>
      <link>https://example.com/posts/2</link>
      <guid isPermaLink="false">post-2</guid>
      <dc:date>2026-09-22T10:00:00+09:00</dc:date>
      <enclosure url="https://example.com/2.png" type="image/png" length="10"/>
    </item>
    <item>
      <title>日本語のURL</title>
      <link>https://example.com/posts/日本語?q="x"</link>
      <guid isPermaLink="false">post-3</guid>
      <pubDate>Mon, 22 Sep 2026 11:00:00 GMT</pubDate>
      <pubDate>Mon, 22 Sep 2026 08:00:00 GMT</pubDate>
    </item>
    <item>
      <title>No guid, link only</title>
      <link>https://example.com/posts/4</link>
      <pubDate>22 Sep 2026 12:00:00 +0000</pubDate>
    </item>
  </channel>
</rss>
```

`fetcher/testdata/fixtures/rss_edge.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
  <channel>
    <title>Edge RSS</title>
    <link>https://example.com/edge</link>
    <description>edge cases</description>
    <item>
      <title>   </title>
      <link>https://example.com/blank-title</link>
      <guid isPermaLink="false">blank-title</guid>
      <pubDate>Tue, 23 Sep 2026 09:00:00 +0900</pubDate>
    </item>
    <item>
      <title>AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA</title>
      <link>https://example.com/long-title</link>
      <guid isPermaLink="false">long-title</guid>
      <pubDate>Tue, 23 Sep 2026 09:10:00 +0900</pubDate>
    </item>
    <item>
      <title>Bad image</title>
      <link>https://example.com/bad-image</link>
      <guid isPermaLink="false">bad-image</guid>
      <pubDate>Tue, 23 Sep 2026 09:20:00 +0900</pubDate>
      <media:thumbnail url="javascript:alert(1)"/>
    </item>
    <item>
      <title>Entity in description</title>
      <link>https://example.com/entity</link>
      <guid isPermaLink="false">entity</guid>
      <pubDate>Tue, 23 Sep 2026 09:30:00 +0900</pubDate>
      <description>a&nbsp;b &amp; c &#x3042;</description>
    </item>
    <item>
      <title>No url no guid</title>
      <pubDate>Tue, 23 Sep 2026 09:40:00 +0900</pubDate>
    </item>
    <item>
      <title>Mailto link</title>
      <link>mailto:someone@example.com</link>
      <guid isPermaLink="false">mailto</guid>
      <pubDate>Tue, 23 Sep 2026 09:50:00 +0900</pubDate>
    </item>
    <item>
      <title>Unparseable date</title>
      <link>https://example.com/bad-date</link>
      <guid isPermaLink="false">bad-date</guid>
      <pubDate>not a date</pubDate>
    </item>
    <item>
      <title>JST date</title>
      <link>https://example.com/jst</link>
      <guid isPermaLink="false">jst</guid>
      <pubDate>Tue, 23 Sep 2026 10:00:00 JST</pubDate>
    </item>
  </channel>
</rss>
```

(長いタイトルの `A` は300個。エディタで `A` を300個並べること。)

`fetcher/testdata/fixtures/itunes_podcast.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <channel>
    <title><![CDATA[Podcast]]></title>
    <link>https://example.com/podcast</link>
    <description>A podcast</description>
    <itunes:image href="https://example.com/cover.jpg"/>
    <itunes:owner><itunes:name>owner</itunes:name><itunes:email>owner@example.com</itunes:email></itunes:owner>
    <itunes:category text="Technology"><itunes:category text="Podcasting"/></itunes:category>
    <item>
      <title>Episode 1</title>
      <link>https://example.com/podcast/1</link>
      <guid isPermaLink="false">ep1</guid>
      <pubDate>Wed, 24 Sep 2026 06:00:00 +0000</pubDate>
      <description>episode one</description>
      <itunes:subtitle>sub one</itunes:subtitle>
      <itunes:image href="https://example.com/ep1.jpg"/>
      <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg" length="123"/>
    </item>
    <item>
      <title>Episode 2 without link</title>
      <guid isPermaLink="false">ep2</guid>
      <pubDate>Thu, 25 Sep 2026 06:00:00 +0000</pubDate>
      <enclosure url="https://example.com/ep2.mp3" type="audio/mpeg" length="456"/>
    </item>
    <item>
      <title>Episode 3 without date</title>
      <link>https://example.com/podcast/3</link>
      <guid isPermaLink="false">ep3</guid>
      <enclosure url="https://example.com/ep3.mp3" type="audio/mpeg" length="789"/>
    </item>
  </channel>
</rss>
```

`fetcher/testdata/fixtures/atom_basic.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
  <title>Atom Basic</title>
  <subtitle>atom subtitle</subtitle>
  <link href="https://example.com/atom/feed.xml" rel="self"/>
  <link href="https://example.com/atom/" rel="alternate" type="text/html"/>
  <id>tag:example.com,2026:atom</id>
  <updated>2026-09-24T00:00:00Z</updated>
  <author><name>author</name></author>
  <entry>
    <title type="html">&lt;b&gt;Bold&lt;/b&gt;   title</title>
    <link href="https://example.com/atom/1" rel="alternate" type="text/html"/>
    <id>tag:example.com,2026:1</id>
    <published>2026-09-24T01:00:00+09:00</published>
    <updated>2026-09-24T02:00:00+09:00</updated>
    <summary>summary one</summary>
    <media:thumbnail url="https://example.com/atom/1.jpg"/>
  </entry>
  <entry>
    <title>Updated only</title>
    <link href="https://example.com/atom/2"/>
    <id>tag:example.com,2026:2</id>
    <updated>2026-09-24T03:00:00Z</updated>
    <updated>2026-09-24T04:00:00Z</updated>
  </entry>
</feed>
```

`fetcher/testdata/fixtures/atom_https_ns.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="https://www.w3.org/2005/Atom">
  <title>Wrong Namespace</title>
  <link href="https://example.com/ns/" rel="alternate" type="text/html"/>
  <entry>
    <title>ns entry</title>
    <link href="https://example.com/ns/1" rel="alternate" type="text/html"/>
    <id>ns-1</id>
    <published>2026-09-24T01:00:00Z</published>
  </entry>
</feed>
```

`fetcher/testdata/fixtures/rss_entity_copyright.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <copyright>&copy; 2026 Example</copyright>
    <generator>Gen &trade;</generator>
    <title>Entity Copyright</title>
    <link>https://example.com/entity</link>
    <description>entity desc</description>
    <item>
      <title>entity item</title>
      <link>https://example.com/entity/1</link>
      <guid isPermaLink="false">entity-1</guid>
      <pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate>
    </item>
  </channel>
</rss>
```

`fetcher/testdata/fixtures/rss_relative_urls.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Relative URLs</title>
    <link>/</link>
    <description>relative</description>
    <item>
      <title>root relative</title>
      <link>/post/1/</link>
      <guid isPermaLink="false">rel-1</guid>
      <pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate>
    </item>
    <item>
      <title>path relative</title>
      <link>post/2/</link>
      <guid isPermaLink="false">rel-2</guid>
      <pubDate>Wed, 24 Sep 2026 01:00:00 +0000</pubDate>
    </item>
  </channel>
</rss>
```

`fetcher/testdata/fixtures/rss_relative_urls.url`:

```
https://example.com:8080/blog/index.xml
```

`fetcher/testdata/fixtures/youtube.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
  <link rel="self" href="http://www.youtube.com/feeds/videos.xml?channel_id=UCexample"/>
  <id>yt:channel:UCexample</id>
  <yt:channelId>UCexample</yt:channelId>
  <title>Example Channel</title>
  <link rel="alternate" href="https://www.youtube.com/channel/UCexample"/>
  <author><name>Example Channel</name><uri>https://www.youtube.com/channel/UCexample</uri></author>
  <published>2020-01-01T00:00:00+00:00</published>
  <entry>
    <id>yt:video:VIDEO00001</id>
    <yt:videoId>VIDEO00001</yt:videoId>
    <yt:channelId>UCexample</yt:channelId>
    <title>Video 1</title>
    <link rel="alternate" href="https://www.youtube.com/watch?v=VIDEO00001"/>
    <author><name>Example Channel</name></author>
    <published>2026-09-24T00:00:00+00:00</published>
    <updated>2026-09-24T01:00:00+00:00</updated>
    <media:group>
      <media:title>Video 1</media:title>
      <media:content url="https://www.youtube.com/v/VIDEO00001" type="application/x-shockwave-flash" width="640" height="390"/>
      <media:thumbnail url="https://i1.ytimg.com/vi/VIDEO00001/hqdefault.jpg" width="480" height="360"/>
      <media:description>video description</media:description>
    </media:group>
  </entry>
</feed>
```

`fetcher/testdata/fixtures/google_alerts.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:idx="urn:atom-extension:indexing">
  <id>tag:google.com,2005:reader/user/00000000000000000000/state/com.google/alerts/1234567890</id>
  <title>Google Alert - example</title>
  <link href="https://www.google.com/alerts/feeds/00000000000000000000/1234567890" rel="self"/>
  <updated>2026-09-24T00:00:00Z</updated>
  <entry>
    <id>tag:google.com,2013:googlealerts/feed:1</id>
    <title type="html">&lt;b&gt;example&lt;/b&gt; news</title>
    <link href="https://www.google.com/url?rct=j&amp;sa=t&amp;url=https://news.example.com/a&amp;ct=ga"/>
    <published>2026-09-24T00:00:00Z</published>
    <updated>2026-09-24T00:00:00Z</updated>
    <content type="html">content</content>
  </entry>
  <entry>
    <id>tag:google.com,2013:googlealerts/feed:2</id>
    <title>direct link</title>
    <link href="https://news.example.com/b"/>
    <published>2026-09-24T01:00:00Z</published>
  </entry>
</feed>
```

`fetcher/testdata/fixtures/rss_invalid_utf8.xml` は不正バイトを含むので、シェルで作る:

```bash
printf '<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0"><channel><title>Invalid \xff\xfe bytes</title><link>https://example.com/bytes</link><description>d</description><item><title>item \xc3\x28 x</title><link>https://example.com/bytes/1</link><guid isPermaLink="false">bytes-1</guid><pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate></item></channel></rss>\n' > fetcher/testdata/fixtures/rss_invalid_utf8.xml
```

- [ ] **Step 3: golden を生成して中身を確かめる**

Run: `docker compose run --rm web rails "fetcher:golden[fetcher/testdata/fixtures]"`
Expected: 10個すべてで `wrote <name>.golden.json` が出る (`FAILED` が無い)

生成された golden を目で確かめる。少なくとも次を確認し、想定と違えば Rails の挙動として正しいか (= Rust が合わせるべきものか) をメモしてから進む。

- `rss_edge.golden.json`: `blank-title` の title が `〓`、`long-title` / `mailto` / `bad-date` が `validation_failed`、`No url no guid` が `no_guid` か `no_url`、`bad-image` の `image_url` が null
- `itunes_podcast.golden.json`: `format` が `itunes_rss`、`channel.image_url` が cover.jpg、`ep2` の url が enclosure の URL、`ep3` が `validation_failed`
- `rss_relative_urls.golden.json`: `applied_filters` が `["RelativeUrlResolver"]`、url が `https://example.com:8080/post/1/` と `https://example.com:8080/post/2/`
- `atom_https_ns.golden.json`: `applied_filters` が `["AtomNamespaceFixer"]`
- `rss_entity_copyright.golden.json`: `applied_filters` が `["HtmlEntityFixer"]`
- `youtube.golden.json`: `image_url` が `https://img.youtube.com/vi/VIDEO00001/maxresdefault.jpg`

- [ ] **Step 4: golden テストの枠を書く**

`fetcher/tests/golden.rs`:

```rust
use std::fs;
use std::path::{Path, PathBuf};

use fetcher::model::ShapedFeed;
use pretty_assertions::assert_eq;

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata/fixtures")
}

pub fn feed_url_for(dir: &Path, name: &str) -> String {
    let url_path = dir.join(format!("{name}.url"));
    match fs::read_to_string(&url_path) {
        Ok(s) => s.lines().next().unwrap_or_default().trim().to_string(),
        Err(_) => format!("https://example.com/{name}/feed.xml"),
    }
}

fn check(name: &str) {
    let dir = fixtures_dir();
    let body = fs::read(dir.join(format!("{name}.xml"))).unwrap();
    let golden: ShapedFeed =
        serde_json::from_str(&fs::read_to_string(dir.join(format!("{name}.golden.json"))).unwrap())
            .unwrap();
    let mut actual = fetcher::golden_output(&body, &feed_url_for(&dir, name)).unwrap();
    actual.normalize_order();
    assert_eq!(golden, actual, "fixture: {name}");
}

macro_rules! golden_tests {
    ($($name:ident),* $(,)?) => {
        $(
            #[test]
            #[ignore = "Task 6 で有効にする"]
            fn $name() { check(stringify!($name)); }
        )*
    };
}

golden_tests!(
    rss_basic,
    rss_edge,
    itunes_podcast,
    atom_basic,
    atom_https_ns,
    rss_entity_copyright,
    rss_relative_urls,
    youtube,
    google_alerts,
    rss_invalid_utf8,
);
```

- [ ] **Step 5: ビルドを確認する**

Run: `cd fetcher && cargo test`
Expected: コンパイルが通り、golden テスト10件は ignored

- [ ] **Step 6: コミット**

```bash
git add .gitignore fetcher/Cargo.toml fetcher/Cargo.lock fetcher/src fetcher/tests fetcher/testdata
git commit -m "fetcherクレートの土台と合成フィクスチャのgoldenを追加"
```

---

### Task 3: Ruby 互換の小道具・文字コード・パース前フィルタ

**Files:**
- Create: `fetcher/src/ruby.rs`, `fetcher/src/encoding.rs`
- Create: `fetcher/src/filters/mod.rs`, `fetcher/src/filters/html_entity_fixer.rs`, `fetcher/src/filters/atom_namespace_fixer.rs`
- Modify: `fetcher/src/lib.rs` (`pub mod ruby; pub mod encoding; pub mod filters;`)

**Interfaces:**
- Produces (`ruby.rs`):
  - `fn is_blank(s: &str) -> bool` (Ruby の `blank?`。空か Unicode の空白だけ)
  - `fn opt_presence(s: Option<&str>) -> Option<&str>` (`presence`)
  - `fn ruby_strip(s: &str) -> &str` (`String#strip`。NUL, \t, \n, \v, \f, \r, 空白を両端から除く)
  - `fn matches_uri_http(s: &str) -> bool` (`s =~ URI.regexp(%w[http https])` 相当。部分一致)
  - `fn valid_url_column(s: &str) -> bool` (`validates_url_http_format_of` 相当: URI 判定 + 4096文字以内)
- Produces (`encoding.rs`): `fn to_utf8_dropping_invalid(bytes: &[u8]) -> String`
- Produces (`filters/mod.rs`):
  - `trait PreParseFilter { fn name(&self) -> &'static str; fn apply(&self, xml: &str) -> Option<(String, serde_json::Value)>; }` (適用したときだけ `Some((新しいXML, details))`)
  - `fn apply_pre_parse(xml: String) -> (String, Vec<String>, serde_json::Map<String, serde_json::Value>)` (適用順は HtmlEntityFixer → AtomNamespaceFixer)

- [ ] **Step 1: 失敗するテストを書く**

`fetcher/src/ruby.rs` の末尾に置くテスト:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blank_matches_ruby() {
        assert!(is_blank(""));
        assert!(is_blank(" \t\n"));
        assert!(is_blank("\u{3000}"));
        assert!(!is_blank(" a "));
    }

    #[test]
    fn strip_matches_ruby() {
        assert_eq!(ruby_strip("\0 a b \t\n"), "a b");
        assert_eq!(ruby_strip("\u{3000}a\u{3000}"), "\u{3000}a\u{3000}");
    }

    #[test]
    fn uri_http_is_partial_match_like_ruby() {
        assert!(matches_uri_http("https://example.com/a"));
        assert!(matches_uri_http("see http://example.com"));
        assert!(matches_uri_http("HTTP://EXAMPLE.COM"));
        assert!(!matches_uri_http("javascript:alert(1)"));
        assert!(!matches_uri_http("mailto:someone@example.com"));
        assert!(!matches_uri_http("/relative/path"));
    }

    #[test]
    fn url_column_has_length_limit() {
        let long = format!("https://example.com/{}", "a".repeat(4096));
        assert!(!valid_url_column(&long));
    }
}
```

`fetcher/src/encoding.rs` のテスト:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_invalid_bytes_and_keeps_valid_text() {
        assert_eq!(to_utf8_dropping_invalid(b"a\xff\xfeb\xc3\x28c"), "ab(c");
        assert_eq!(to_utf8_dropping_invalid("日本語".as_bytes()), "日本語");
    }
}
```

`fetcher/src/filters/html_entity_fixer.rs` のテスト (Ruby の `test/services/feed_filters/pre_parse/html_entity_fixer_test.rb` の観点を移植):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::filters::PreParseFilter;

    #[test]
    fn decodes_entities_in_copyright_and_generator() {
        let xml = "<rss><channel><copyright>&copy; 2026</copyright><generator>G &trade;</generator><title>t &amp; u</title></channel></rss>";
        let (fixed, details) = HtmlEntityFixer.apply(xml).unwrap();
        assert!(fixed.contains("<copyright>© 2026</copyright>"));
        assert!(fixed.contains("<generator>G ™</generator>"));
        assert!(fixed.contains("<title>t &amp; u</title>"));
        assert_eq!(details["fixed_tags"], serde_json::json!(["copyright", "generator"]));
    }

    #[test]
    fn not_applicable_without_entities() {
        assert!(HtmlEntityFixer.apply("<rss><channel><copyright>2026</copyright></channel></rss>").is_none());
    }

    #[test]
    fn re_escapes_xml_special_chars() {
        let xml = "<rss><channel><copyright>&copy; A &lt; B</copyright></channel></rss>";
        let (fixed, _) = HtmlEntityFixer.apply(xml).unwrap();
        assert!(fixed.contains("<copyright>© A &lt; B</copyright>"));
    }
}
```

`fetcher/src/filters/atom_namespace_fixer.rs` のテスト:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::filters::PreParseFilter;

    #[test]
    fn fixes_https_namespace_with_both_quotes() {
        let (fixed, details) = AtomNamespaceFixer.apply(r#"<feed xmlns="https://www.w3.org/2005/Atom">"#).unwrap();
        assert_eq!(fixed, r#"<feed xmlns="http://www.w3.org/2005/Atom">"#);
        assert_eq!(details["original_namespace"], r#"xmlns="https://www.w3.org/2005/Atom""#);

        let (fixed, _) = AtomNamespaceFixer.apply("<feed xmlns='https://www.w3.org/2005/Atom'>").unwrap();
        assert_eq!(fixed, "<feed xmlns='http://www.w3.org/2005/Atom'>");
    }

    #[test]
    fn not_applicable_for_correct_namespace() {
        assert!(AtomNamespaceFixer.apply(r#"<feed xmlns="http://www.w3.org/2005/Atom">"#).is_none());
    }
}
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `cd fetcher && cargo test --lib`
Expected: コンパイルエラー (関数が未定義)

- [ ] **Step 3: 実装する**

`fetcher/src/ruby.rs`:

```rust
//! Rails の挙動に合わせるための、Ruby 互換の小さな関数たち。

use std::sync::LazyLock;

use regex::Regex;

pub const URL_MAX_LENGTH: usize = 4096;

/// Ruby の `blank?` (空文字、または Unicode の空白だけ)
pub fn is_blank(s: &str) -> bool {
    s.chars().all(char::is_whitespace)
}

/// Ruby の `presence`
pub fn opt_presence(s: Option<&str>) -> Option<&str> {
    s.filter(|v| !is_blank(v))
}

/// Ruby の `String#strip` (NUL と ASCII の空白だけを除く)
pub fn ruby_strip(s: &str) -> &str {
    s.trim_matches(|c| matches!(c, '\0' | '\t' | '\n' | '\x0b' | '\x0c' | '\r' | ' '))
}

// Ruby の URI.regexp(%w[http https]) は位置を固定しない部分一致なので、
// 「http: か https: の後に URI の文字が1つ以上続く箇所があるか」で近似する。
static URI_HTTP: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)https?:[A-Za-z0-9\-_.!~*'();/?:@&=+$,%\[\]#]").unwrap()
});

pub fn matches_uri_http(s: &str) -> bool {
    URI_HTTP.is_match(s)
}

/// `validates_url_http_format_of` 相当 (nil は呼び出し側で許可する)
pub fn valid_url_column(s: &str) -> bool {
    matches_uri_http(s) && s.chars().count() <= URL_MAX_LENGTH
}
```

`fetcher/src/encoding.rs`:

```rust
/// HTTP のレスポンスを UTF-8 として解釈し、不正なバイト列は取り除く。
/// Rails の `force_encoding("UTF-8").encode("UTF-8", invalid: :replace, replace: "")` と同じ。
pub fn to_utf8_dropping_invalid(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len());
    for chunk in bytes.utf8_chunks() {
        out.push_str(chunk.valid());
    }
    out
}
```

`fetcher/src/filters/mod.rs`:

```rust
pub mod atom_namespace_fixer;
pub mod html_entity_fixer;
pub mod relative_url_resolver;

use serde_json::{Map, Value};

/// XML 文字列に対してかけるフィルタ。適用したときだけ Some を返す。
pub trait PreParseFilter {
    fn name(&self) -> &'static str;
    fn apply(&self, xml: &str) -> Option<(String, Value)>;
}

/// Ruby の FeedNormalizer::PRE_PARSE_FILTERS と同じ順番でかける。
pub fn apply_pre_parse(xml: String) -> (String, Vec<String>, Map<String, Value>) {
    let filters: [&dyn PreParseFilter; 2] = [
        &html_entity_fixer::HtmlEntityFixer,
        &atom_namespace_fixer::AtomNamespaceFixer,
    ];
    let mut current = xml;
    let mut applied = Vec::new();
    let mut details = Map::new();
    for filter in filters {
        if let Some((fixed, detail)) = filter.apply(&current) {
            current = fixed;
            applied.push(filter.name().to_string());
            details.insert(filter.name().to_string(), detail);
        }
    }
    (current, applied, details)
}
```

(`relative_url_resolver` は Task 6 で作る。この Task では `fetcher/src/filters/relative_url_resolver.rs` を空ファイルで作っておく。)

`fetcher/src/filters/html_entity_fixer.rs`:

```rust
//! copyright / generator の中の HTML エンティティを実際の文字に直す。
//! Ruby 版は Nokogiri で文書全体を読み直すが、ここでは対象タグの中身だけを書き換える。

use std::sync::LazyLock;

use regex::Regex;
use serde_json::json;

use super::PreParseFilter;

const TARGET_TAGS: [&str; 2] = ["copyright", "generator"];

static APPLICABLE: LazyLock<Vec<(&'static str, Regex)>> = LazyLock::new(|| {
    TARGET_TAGS
        .iter()
        .map(|tag| (*tag, Regex::new(&format!(r"<{tag}[^>]*>([^<]*)&[a-zA-Z]+;")).unwrap()))
        .collect()
});

static ELEMENT: LazyLock<Vec<(&'static str, Regex)>> = LazyLock::new(|| {
    TARGET_TAGS
        .iter()
        .map(|tag| (*tag, Regex::new(&format!(r"(<{tag}(?:\s[^>]*)?>)([^<]*)(</{tag}>)")).unwrap()))
        .collect()
});

pub struct HtmlEntityFixer;

fn xml_escape_text(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

impl PreParseFilter for HtmlEntityFixer {
    fn name(&self) -> &'static str {
        "HtmlEntityFixer"
    }

    fn apply(&self, xml: &str) -> Option<(String, serde_json::Value)> {
        let applicable = APPLICABLE
            .iter()
            .any(|(tag, re)| xml.contains(&format!("<{tag}")) && re.is_match(xml));
        if !applicable {
            return None;
        }

        let mut current = xml.to_string();
        let mut fixed_tags: Vec<&str> = Vec::new();
        for (tag, re) in ELEMENT.iter() {
            let replaced = re.replace_all(&current, |caps: &regex::Captures| {
                let decoded = html_escape::decode_html_entities(&caps[2]).to_string();
                format!("{}{}{}", &caps[1], xml_escape_text(&decoded), &caps[3])
            });
            if replaced != current {
                fixed_tags.push(tag);
                current = replaced.into_owned();
            }
        }

        if fixed_tags.is_empty() {
            return None;
        }
        Some((
            current,
            json!({ "fixed_tags": fixed_tags, "reason": "HTML entities in tags converted to actual characters" }),
        ))
    }
}
```

`fetcher/src/filters/atom_namespace_fixer.rs`:

```rust
use serde_json::json;

use super::PreParseFilter;

const DOUBLE: &str = r#"xmlns="https://www.w3.org/2005/Atom""#;
const SINGLE: &str = "xmlns='https://www.w3.org/2005/Atom'";

pub struct AtomNamespaceFixer;

impl PreParseFilter for AtomNamespaceFixer {
    fn name(&self) -> &'static str {
        "AtomNamespaceFixer"
    }

    fn apply(&self, xml: &str) -> Option<(String, serde_json::Value)> {
        if !xml.contains(DOUBLE) && !xml.contains(SINGLE) {
            return None;
        }
        let mut modified = xml.to_string();
        let mut original = None;
        if modified.contains(DOUBLE) {
            original = Some(DOUBLE);
            modified = modified.replace(DOUBLE, r#"xmlns="http://www.w3.org/2005/Atom""#);
        }
        if modified.contains(SINGLE) {
            original = Some(SINGLE);
            modified = modified.replace(SINGLE, "xmlns='http://www.w3.org/2005/Atom'");
        }
        let original = original.unwrap();
        Some((
            modified,
            json!({
                "fixed": "Atom namespace URL protocol",
                "original_namespace": original,
                "corrected_namespace": original.replace("https:", "http:"),
            }),
        ))
    }
}
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `cd fetcher && cargo test --lib`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add fetcher/src
git commit -m "fetcherにRuby互換の小道具・文字コード処理・パース前フィルタを追加"
```

---

### Task 4: sax-machine 互換のパースエンジン

Feedjira は sax-machine で「クラスごとの要素ルール」に従って値を集める。この挙動を Rust で再現する小さなエンジンを作る。再現する規則は次のとおり (sax-machine 1.3.2 の `SAXAbstractHandler` より)。

1. 要素名の `-` は `_` に置き換えてから照合する。名前空間は URI ではなく、書かれたままの接頭辞付きの名前 (`itunes:image` など) で照合する
2. 開始タグでは次の順で処理する
   - いまのオブジェクトのクラスに、同じ名前の **Collection ルール** (`elements :item, class: ...`) があれば、新しいオブジェクトを作って積む。以降の手順はその新しいオブジェクトに対して行う
   - 名前と属性条件が合う **Attr ルール** (`value: :href`) をすべて処理する。まだ一度も値を入れていないルールなら、属性の値を入れて「済み」にする (Append のルールは済みにしない)
   - Collection を積んでいなければ、名前と属性条件が合う最初の **Text ルール** か **Child ルール** を探す。Text ルールならいまのオブジェクトのまま積み、Child ルールなら新しいオブジェクトを作って積む。Child と Collection のオブジェクトには、そのクラスの属性ルール (`attribute :isPermaLink`) を当てはめる
3. 文字データ (CDATA を含む) は、スタックのいちばん上の区切りのバッファに足していく。ルールの無い子要素の文字もここに入る
4. 終了タグでは、スタックのいちばん上の区切りのルール名と一致するときだけ処理して、区切りを1つ下ろす。一致しないときは何もしない
   - 親オブジェクトでまだ「済み」でないときだけ値を入れる。Text ならバッファが空でないときだけ入れて、空のときも「済み」にする。Child ならそのクラスの `value_field` にバッファを入れてから親に付けて「済み」にする。Collection なら親のリストに足すだけにする (済みにしない)
5. 属性条件は `Eq(属性名, 値)` と `Absent(属性名)` (`with: { type: nil }`) の組み合わせ。条件が空なら属性は問わない
6. 値の入れ方は4種類: `Plain` (上書き)、`KeepOldest` (日時として解釈できたとき、それまでより古ければ上書き。`published=`)、`KeepNewest` (新しければ上書き。`updated=`)、`Append` (リストに足す)

**Files:**
- Create: `fetcher/src/parse/mod.rs`, `fetcher/src/parse/sax.rs`, `fetcher/src/parse/date.rs`
- Modify: `fetcher/src/lib.rs` (`pub mod parse;`)

**Interfaces:**
- Produces (`parse/date.rs`): `fn parse_datetime(s: &str) -> Option<chrono::DateTime<chrono::Utc>>`
- Produces (`parse/sax.rs`):

```rust
pub enum Cond { Eq(&'static str, &'static str), Absent(&'static str) }
pub enum Setter { Plain, KeepOldest, KeepNewest, Append }
pub enum Rule {
    Text { name: &'static str, with: &'static [Cond], field: &'static str, setter: Setter },
    Attr { name: &'static str, with: &'static [Cond], attr: &'static str, field: &'static str, setter: Setter },
    Child { name: &'static str, with: &'static [Cond], class: &'static Class, field: &'static str },
    Collection { name: &'static str, class: &'static Class, field: &'static str },
}
pub struct Class { pub rules: &'static [Rule], pub value_field: Option<&'static str>, pub attr_fields: &'static [(&'static str, &'static str)] }
#[derive(Debug, Default, Clone)]
pub struct Obj { pub fields: HashMap<&'static str, Vec<String>>, pub children: HashMap<&'static str, Vec<Obj>> }
impl Obj {
    pub fn get(&self, field: &str) -> Option<&str>;          // 最後の値
    pub fn all(&self, field: &str) -> &[String];            // Append の値
    pub fn child(&self, field: &str) -> Option<&Obj>;
    pub fn list(&self, field: &str) -> &[Obj];
}
pub fn parse(xml: &str, root: &'static Class) -> Obj
```

`KeepOldest` / `KeepNewest` の値は `parse_datetime` した結果を RFC3339 (`2026-09-24T01:00:00+00:00`) で持つ。

- [ ] **Step 1: 失敗するテストを書く**

`fetcher/src/parse/date.rs` のテスト:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn iso(s: &str) -> String {
        parse_datetime(s).unwrap().format("%Y-%m-%dT%H:%M:%SZ").to_string()
    }

    #[test]
    fn parses_common_formats_like_ruby_datetime_parse() {
        assert_eq!(iso("Wed, 24 Sep 2026 10:00:00 +0900"), "2026-09-24T01:00:00Z");
        assert_eq!(iso("Wed, 24 Sep 2026 10:00:00 GMT"), "2026-09-24T10:00:00Z");
        assert_eq!(iso("Wed, 24 Sep 2026 10:00:00 JST"), "2026-09-24T01:00:00Z");
        assert_eq!(iso("Mon, 24 Sep 2026 10:00:00 +0900"), "2026-09-24T01:00:00Z"); // 曜日の不一致は無視
        assert_eq!(iso("24 Sep 2026 10:00:00 +0000"), "2026-09-24T10:00:00Z");
        assert_eq!(iso("2026-09-24T10:00:00+09:00"), "2026-09-24T01:00:00Z");
        assert_eq!(iso("2026-09-24T10:00:00.123Z"), "2026-09-24T10:00:00Z");
        assert_eq!(iso("2026-09-24 10:00:00"), "2026-09-24T10:00:00Z"); // タイムゾーン無しは UTC
        assert_eq!(iso("2026-09-24"), "2026-09-24T00:00:00Z");
    }

    #[test]
    fn returns_none_for_garbage() {
        assert!(parse_datetime("not a date").is_none());
        assert!(parse_datetime("").is_none());
    }
}
```

`fetcher/src/parse/sax.rs` のテスト:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    static GUID: Class = Class { rules: &[], value_field: Some("guid"), attr_fields: &[("isPermaLink", "is_perma_link")] };
    static IMAGE: Class = Class { rules: &[], value_field: None, attr_fields: &[] };
    static ENTRY: Class = Class {
        rules: &[
            Rule::Text { name: "title", with: &[], field: "title", setter: Setter::Plain },
            Rule::Text { name: "pubDate", with: &[], field: "published", setter: Setter::KeepOldest },
            Rule::Child { name: "guid", with: &[], class: &GUID, field: "entry_id" },
            Rule::Attr { name: "link", with: &[Cond::Eq("rel", "alternate")], attr: "href", field: "url", setter: Setter::Plain },
            Rule::Attr { name: "link", with: &[], attr: "href", field: "links", setter: Setter::Append },
            Rule::Text { name: "t", with: &[Cond::Absent("type")], field: "plain_t", setter: Setter::Plain },
            Rule::Text { name: "t", with: &[Cond::Eq("type", "html")], field: "html_t", setter: Setter::Plain },
        ],
        value_field: None,
        attr_fields: &[],
    };
    static FEED: Class = Class {
        rules: &[
            Rule::Text { name: "title", with: &[], field: "title", setter: Setter::Plain },
            Rule::Child { name: "image", with: &[], class: &IMAGE, field: "image" },
            Rule::Collection { name: "item", class: &ENTRY, field: "entries" },
        ],
        value_field: None,
        attr_fields: &[],
    };

    #[test]
    fn first_value_wins_per_rule_and_nested_context_is_isolated() {
        let xml = r#"<rss><channel>
            <image><title>image title</title></image>
            <title>Feed</title><title>Second</title>
            <item><title>A</title><guid isPermaLink="false">g1</guid></item>
        </channel></rss>"#;
        let feed = parse(xml, &FEED);
        assert_eq!(feed.get("title"), Some("Feed"));
        let entry = &feed.list("entries")[0];
        assert_eq!(entry.get("title"), Some("A"));
        let guid = entry.child("entry_id").unwrap();
        assert_eq!(guid.get("guid"), Some("g1"));
        assert_eq!(guid.get("is_perma_link"), Some("false"));
    }

    #[test]
    fn attr_rules_cdata_entities_and_keep_oldest() {
        let xml = r#"<rss><item>
            <title><![CDATA[<b>x</b>]]> &amp; y</title>
            <link rel="alternate" href="https://e/1"/><link href="https://e/2"/>
            <pubDate>Wed, 24 Sep 2026 11:00:00 +0000</pubDate>
            <pubDate>Wed, 24 Sep 2026 09:00:00 +0000</pubDate>
            <t>plain</t><t type="html">html</t>
        </item></rss>"#;
        let feed = parse(xml, &FEED);
        let entry = &feed.list("entries")[0];
        assert_eq!(entry.get("title"), Some("<b>x</b> & y"));
        assert_eq!(entry.get("url"), Some("https://e/1"));
        assert_eq!(entry.all("links"), &["https://e/1".to_string(), "https://e/2".to_string()]);
        // 同じルールは最初の1回だけ (2つ目の pubDate は無視される)
        assert_eq!(entry.get("published"), Some("2026-09-24T11:00:00+00:00"));
        assert_eq!(entry.get("plain_t"), Some("plain"));
        assert_eq!(entry.get("html_t"), Some("html"));
    }

    #[test]
    fn empty_element_marks_rule_as_done_without_value() {
        let xml = "<rss><item><title></title><title>later</title></item></rss>";
        let feed = parse(xml, &FEED);
        assert_eq!(feed.list("entries")[0].get("title"), None);
    }

    #[test]
    fn unknown_entities_are_dropped_and_parsing_continues() {
        let xml = "<rss><item><title>a&nbsp;b</title></item><item><title>c</title></item></rss>";
        let feed = parse(xml, &FEED);
        assert_eq!(feed.list("entries").len(), 2);
    }
}
```

`unknown_entities_are_dropped_and_parsing_continues` の期待値 (未定義のエンティティを捨てるか残すか) は、Task 2 の `rss_edge.golden.json` の `entity` の summary を見て Rails に合わせる。golden で `a b` のように消えていれば捨てる実装に、別の形なら golden に合わせた実装とアサーションにする。

- [ ] **Step 2: テストが失敗することを確認する**

Run: `cd fetcher && cargo test --lib parse`
Expected: コンパイルエラー

- [ ] **Step 3: 実装する**

`fetcher/src/parse/date.rs`:

```rust
//! Feedjira の `DateTime.parse(string).to_time.utc` の近似。
//! 読めない形式は None (Feedjira も nil にする)。

use chrono::{DateTime, FixedOffset, NaiveDate, NaiveDateTime, TimeZone, Utc};

const ZONES: [(&str, &str); 12] = [
    ("JST", "+0900"), ("KST", "+0900"), ("GMT", "+0000"), ("UTC", "+0000"), ("UT", "+0000"),
    ("EST", "-0500"), ("EDT", "-0400"), ("CST", "-0600"), ("CDT", "-0500"),
    ("MST", "-0700"), ("PST", "-0800"), ("PDT", "-0700"),
];

const WITH_ZONE: [&str; 6] = [
    "%a, %d %b %Y %H:%M:%S %z",
    "%d %b %Y %H:%M:%S %z",
    "%a, %d %b %Y %H:%M %z",
    "%Y-%m-%d %H:%M:%S %z",
    "%Y-%m-%d %H:%M:%S%z",
    "%Y-%m-%dT%H:%M:%S%.f%z",
];

const WITHOUT_ZONE: [&str; 6] = [
    "%Y-%m-%dT%H:%M:%S%.f",
    "%Y-%m-%d %H:%M:%S",
    "%a, %d %b %Y %H:%M:%S",
    "%d %b %Y %H:%M:%S",
    "%Y/%m/%d %H:%M:%S",
    "%Y/%m/%d %H:%M",
];

fn replace_zone_abbrev(s: &str) -> String {
    for (abbr, offset) in ZONES {
        if let Some(rest) = s.strip_suffix(abbr) {
            if rest.ends_with(' ') {
                return format!("{rest}{offset}");
            }
        }
    }
    s.to_string()
}

fn strip_weekday(s: &str) -> &str {
    match s.split_once(", ") {
        Some((day, rest)) if day.len() == 3 && day.chars().all(|c| c.is_ascii_alphabetic()) => rest,
        _ => s,
    }
}

fn to_utc(d: DateTime<FixedOffset>) -> DateTime<Utc> {
    d.with_timezone(&Utc)
}

pub fn parse_datetime(s: &str) -> Option<DateTime<Utc>> {
    let t = s.trim();
    if t.is_empty() {
        return None;
    }
    if let Ok(d) = DateTime::parse_from_rfc3339(t) {
        return Some(to_utc(d));
    }
    let normalized = replace_zone_abbrev(t);
    let candidates = [normalized.as_str(), strip_weekday(&normalized)];
    for c in candidates {
        if let Ok(d) = DateTime::parse_from_rfc2822(c) {
            return Some(to_utc(d));
        }
        for fmt in WITH_ZONE {
            if let Ok(d) = DateTime::parse_from_str(c, fmt) {
                return Some(to_utc(d));
            }
        }
        for fmt in WITHOUT_ZONE {
            if let Ok(n) = NaiveDateTime::parse_from_str(c, fmt) {
                return Some(Utc.from_utc_datetime(&n));
            }
        }
    }
    for fmt in ["%Y-%m-%d", "%Y/%m/%d"] {
        if let Ok(d) = NaiveDate::parse_from_str(t, fmt) {
            return Some(Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap()));
        }
    }
    None
}
```

`fetcher/src/parse/sax.rs`:

```rust
//! sax-machine 1.3.2 の値の集め方を再現する小さなエンジン。

use std::collections::{HashMap, HashSet};

use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;

use super::date::parse_datetime;

#[derive(Debug, Clone, Copy)]
pub enum Cond {
    Eq(&'static str, &'static str),
    Absent(&'static str),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Setter {
    Plain,
    KeepOldest,
    KeepNewest,
    Append,
}

pub enum Rule {
    Text { name: &'static str, with: &'static [Cond], field: &'static str, setter: Setter },
    Attr { name: &'static str, with: &'static [Cond], attr: &'static str, field: &'static str, setter: Setter },
    Child { name: &'static str, with: &'static [Cond], class: &'static Class, field: &'static str },
    Collection { name: &'static str, class: &'static Class, field: &'static str },
}

pub struct Class {
    pub rules: &'static [Rule],
    pub value_field: Option<&'static str>,
    pub attr_fields: &'static [(&'static str, &'static str)],
}

#[derive(Debug, Default, Clone)]
pub struct Obj {
    pub fields: HashMap<&'static str, Vec<String>>,
    pub children: HashMap<&'static str, Vec<Obj>>,
}

impl Obj {
    pub fn get(&self, field: &str) -> Option<&str> {
        self.fields.get(field).and_then(|v| v.last()).map(String::as_str)
    }
    pub fn all(&self, field: &str) -> &[String] {
        self.fields.get(field).map(Vec::as_slice).unwrap_or(&[])
    }
    pub fn child(&self, field: &str) -> Option<&Obj> {
        self.children.get(field).and_then(|v| v.last())
    }
    pub fn list(&self, field: &str) -> &[Obj] {
        self.children.get(field).map(Vec::as_slice).unwrap_or(&[])
    }

    fn set(&mut self, field: &'static str, value: String, setter: Setter) {
        match setter {
            Setter::Plain => {
                self.fields.insert(field, vec![value]);
            }
            Setter::Append => self.fields.entry(field).or_default().push(value),
            Setter::KeepOldest | Setter::KeepNewest => {
                let Some(parsed) = parse_datetime(&value) else { return };
                let current = self.get(field).and_then(parse_datetime);
                let replace = match current {
                    None => true,
                    Some(c) if setter == Setter::KeepOldest => parsed < c,
                    Some(c) => parsed > c,
                };
                if replace {
                    self.fields.insert(field, vec![parsed.to_rfc3339()]);
                }
            }
        }
    }
}

enum FrameKind {
    Root,
    /// Text ルール。値はいまのオブジェクトに入れる
    Text(usize),
    /// Child か Collection。新しいオブジェクト
    Object { rule: usize },
}

struct Frame {
    kind: FrameKind,
    name: String,
    buffer: Option<String>,
    /// Object / Root のときだけ使う
    obj: Obj,
    class: &'static Class,
    parsed: HashSet<usize>,
}

fn conds_match(conds: &[Cond], attrs: &HashMap<String, String>) -> bool {
    conds.iter().all(|c| match c {
        Cond::Eq(k, v) => attrs.get(*k).map(String::as_str) == Some(*v),
        Cond::Absent(k) => !attrs.contains_key(*k),
    })
}

fn rule_name(rule: &Rule) -> &'static str {
    match rule {
        Rule::Text { name, .. } | Rule::Attr { name, .. } | Rule::Child { name, .. } | Rule::Collection { name, .. } => name,
    }
}

fn read_attrs(e: &BytesStart) -> HashMap<String, String> {
    e.attributes()
        .with_checks(false)
        .flatten()
        .map(|a| {
            let key = String::from_utf8_lossy(a.key.as_ref()).to_string();
            let value = a
                .unescape_value()
                .map(|v| v.to_string())
                .unwrap_or_else(|_| String::from_utf8_lossy(&a.value).to_string());
            (key, value)
        })
        .collect()
}

fn new_object(class: &'static Class, attrs: &HashMap<String, String>) -> Obj {
    let mut obj = Obj::default();
    for (attr, field) in class.attr_fields {
        if let Some(v) = attrs.get(*attr) {
            obj.set(field, v.clone(), Setter::Plain);
        }
    }
    obj
}

struct Engine {
    stack: Vec<Frame>,
}

impl Engine {
    /// いまの値の入れ先 (いちばん上の Object / Root 区切り) の位置
    fn object_index(&self, upto: usize) -> usize {
        (0..=upto)
            .rev()
            .find(|&i| matches!(self.stack[i].kind, FrameKind::Root | FrameKind::Object { .. }))
            .unwrap()
    }

    fn start(&mut self, raw_name: &str, attrs: HashMap<String, String>) {
        let name = raw_name.replace('-', "_");
        let top = self.stack.len() - 1;
        let mut obj_idx = self.object_index(top);
        let class = self.stack[obj_idx].class;

        let collection = class.rules.iter().enumerate().find(|(_, r)| {
            matches!(r, Rule::Collection { name: n, .. } if *n == name)
        });
        let pushed_collection = if let Some((idx, Rule::Collection { class: child_class, .. })) = collection {
            self.stack.push(Frame {
                kind: FrameKind::Object { rule: idx },
                name: name.clone(),
                buffer: None,
                obj: new_object(child_class, &attrs),
                class: child_class,
                parsed: HashSet::new(),
            });
            obj_idx = self.stack.len() - 1;
            true
        } else {
            false
        };

        let class = self.stack[obj_idx].class;
        for (idx, rule) in class.rules.iter().enumerate() {
            if let Rule::Attr { name: n, with, attr, field, setter } = rule {
                if *n != name || !conds_match(with, &attrs) {
                    continue;
                }
                let frame = &mut self.stack[obj_idx];
                if frame.parsed.contains(&idx) {
                    continue;
                }
                if let Some(v) = attrs.get(*attr) {
                    frame.obj.set(field, v.clone(), *setter);
                }
                if *setter != Setter::Append {
                    frame.parsed.insert(idx);
                }
            }
        }

        if pushed_collection {
            return;
        }

        let found = class.rules.iter().enumerate().find(|(_, r)| match r {
            Rule::Text { name: n, with, .. } | Rule::Child { name: n, with, .. } => {
                *n == name && conds_match(with, &attrs)
            }
            _ => false,
        });
        match found {
            Some((idx, Rule::Text { .. })) => self.stack.push(Frame {
                kind: FrameKind::Text(idx),
                name,
                buffer: None,
                obj: Obj::default(),
                class,
                parsed: HashSet::new(),
            }),
            Some((idx, Rule::Child { class: child_class, .. })) => self.stack.push(Frame {
                kind: FrameKind::Object { rule: idx },
                name,
                buffer: None,
                obj: new_object(child_class, &attrs),
                class: child_class,
                parsed: HashSet::new(),
            }),
            _ => {}
        }
    }

    fn characters(&mut self, text: &str) {
        let top = self.stack.last_mut().unwrap();
        top.buffer.get_or_insert_with(String::new).push_str(text);
    }

    fn end(&mut self, raw_name: &str) {
        let name = raw_name.replace('-', "_");
        if self.stack.len() < 2 {
            return;
        }
        if self.stack.last().unwrap().name != name {
            return;
        }
        let close = self.stack.pop().unwrap();
        let parent_idx = self.object_index(self.stack.len() - 1);
        let parent_class = self.stack[parent_idx].class;

        match close.kind {
            FrameKind::Root => {}
            FrameKind::Text(idx) => {
                let parent = &mut self.stack[parent_idx];
                if parent.parsed.contains(&idx) {
                    return;
                }
                if let Rule::Text { field, setter, .. } = &parent_class.rules[idx] {
                    if let Some(buf) = close.buffer {
                        parent.obj.set(field, buf, *setter);
                    }
                }
                parent.parsed.insert(idx);
            }
            FrameKind::Object { rule } => {
                let mut obj = close.obj;
                if let (Some(value_field), Some(buf)) = (close.class.value_field, close.buffer) {
                    obj.set(value_field, buf, Setter::Plain);
                }
                let parent = &mut self.stack[parent_idx];
                match &parent_class.rules[rule] {
                    Rule::Collection { field, .. } => {
                        parent.obj.children.entry(field).or_default().push(obj);
                    }
                    Rule::Child { field, .. } => {
                        if parent.parsed.contains(&rule) {
                            return;
                        }
                        parent.obj.children.insert(field, vec![obj]);
                        parent.parsed.insert(rule);
                    }
                    _ => {}
                }
            }
        }
    }
}

/// XML を読み、root クラスの規則で値を集める。
/// Nokogiri の SAX と同じく壊れた XML でも止まらず、読めたところまでを返す。
pub fn parse(xml: &str, root: &'static Class) -> Obj {
    let mut reader = Reader::from_str(xml.trim_start_matches('\u{feff}'));
    let config = reader.config_mut();
    config.trim_text(false);
    config.expand_empty_elements = true;
    config.check_end_names = false;

    let mut engine = Engine {
        stack: vec![Frame {
            kind: FrameKind::Root,
            name: String::new(),
            buffer: None,
            obj: Obj::default(),
            class: root,
            parsed: HashSet::new(),
        }],
    };

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                let attrs = read_attrs(&e);
                engine.start(&name, attrs);
            }
            Ok(Event::End(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                engine.end(&name);
            }
            Ok(Event::Text(t)) => {
                if let Ok(text) = t.decode() {
                    engine.characters(&text);
                }
            }
            Ok(Event::CData(c)) => {
                if let Ok(text) = c.decode() {
                    engine.characters(&text);
                }
            }
            Ok(Event::GeneralRef(r)) => {
                if let Ok(Some(ch)) = r.resolve_char_ref() {
                    engine.characters(&ch.to_string());
                } else if let Ok(name) = r.decode() {
                    if let Some(text) = quick_xml::escape::resolve_predefined_entity(&name) {
                        engine.characters(text);
                    }
                    // 未定義のエンティティは捨てる (golden で Rails の挙動を確かめて合わせる)
                }
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(_) => break,
        }
    }

    while engine.stack.len() > 1 {
        let name = engine.stack.last().unwrap().name.clone();
        engine.end(&name);
    }
    engine.stack.pop().unwrap().obj
}
```

quick-xml 0.38 の API (`Event::GeneralRef`、`BytesText::decode`、`BytesRef::resolve_char_ref`、`escape::resolve_predefined_entity`、`Attribute::unescape_value`) は実装時に `cargo doc --open -p quick-xml` で確かめる。名前が違えば、同じ役割のものに置き換える。

`fetcher/src/parse/mod.rs`:

```rust
pub mod date;
pub mod sax;
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `cd fetcher && cargo test --lib parse`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add fetcher/src
git commit -m "fetcherにsax-machine互換のパースエンジンと日時パーサを追加"
```

---

### Task 5: 形式の判別と Feedjira のクラス定義

**Files:**
- Create: `fetcher/src/parse/detect.rs`, `fetcher/src/parse/classes.rs`, `fetcher/src/parse/extract.rs`
- Modify: `fetcher/src/parse/mod.rs`

**Interfaces:**
- Consumes: `sax::{parse, Class, Rule, Cond, Setter, Obj}`、`date::parse_datetime`、`model::FeedFormat`
- Produces (`parse/detect.rs`): `fn detect_format(xml: &str) -> Option<FeedFormat>` (Feedjira の既定のパーサ順と同じ判定)
- Produces (`parse/extract.rs`):

```rust
pub struct RawFeed {
    pub format: FeedFormat,
    pub title: Option<String>,
    pub description: Option<String>,
    /// Feedjira の feed.url (Atom は `@url || (links - [feed_url]).last`)
    pub url: Option<String>,
    /// Atom の links (build_from_atom の site_url に使う)
    pub links: Vec<String>,
    pub itunes_image: Option<String>,
    pub entries: Vec<RawEntry>,
}
pub struct RawEntry {
    pub title: Option<String>,
    pub url: Option<String>,
    pub entry_id: Option<String>,
    pub published: Option<chrono::DateTime<chrono::Utc>>,
    pub summary: Option<String>,
    pub itunes_subtitle: Option<String>,
    pub itunes_image: Option<String>,
    pub image: Option<String>,
    pub enclosure_url: Option<String>,
    pub enclosure_type: Option<String>,
    /// ITunesRSSItem のとき true (Rails の `respond_to?(:enclosure_url)` / `respond_to?(:itunes_image)`)
    pub is_itunes_item: bool,
}
#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("no parser available")] NoParser,
    #[error("unsupported format: {0:?}")] Unsupported(FeedFormat),
}
pub fn parse_feed(xml: &str) -> Result<RawFeed, ParseError>
```

- `google_docs_atom` と `json_feed` は `Unsupported` を返す (本番で使われているかは影モードで確かめる)

- [ ] **Step 1: 失敗するテストを書く**

`fetcher/src/parse/detect.rs` のテスト:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_in_feedjira_order() {
        let itunes = r#"<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel/></rss>"#;
        assert_eq!(detect_format(itunes), Some(FeedFormat::ItunesRss));
        // CDATA の中の itunes 名前空間は無視する
        let in_cdata = r#"<rss><channel><description><![CDATA[xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"]]></description></channel></rss>"#;
        assert_eq!(detect_format(in_cdata), Some(FeedFormat::Rss));
        assert_eq!(detect_format("<rss><channel>feedburner</channel></rss>"), Some(FeedFormat::RssFeedburner));
        let yt = r#"<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">"#;
        assert_eq!(detect_format(yt), Some(FeedFormat::AtomYoutube));
        let alerts = r#"<feed xmlns="http://www.w3.org/2005/Atom"><id>tag:google.com,2005:reader/user/1/state/com.google/alerts/2</id>"#;
        assert_eq!(detect_format(alerts), Some(FeedFormat::AtomGoogleAlerts));
        assert_eq!(detect_format(r#"<feed xmlns="https://www.w3.org/2005/Atom">"#), Some(FeedFormat::Atom));
        assert_eq!(detect_format(r#"{"version":"https://jsonfeed.org/version/1.1"}"#), Some(FeedFormat::JsonFeed));
        assert_eq!(detect_format("<html></html>"), None);
    }
}
```

`fetcher/src/parse/extract.rs` のテスト:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rss_entry_url_falls_back_to_permalink_guid() {
        let xml = r#"<rss><channel><title>T</title><link>https://e/</link>
            <item><guid>https://e/1</guid></item>
            <item><guid isPermaLink="false">x</guid></item>
        </channel></rss>"#;
        let feed = parse_feed(xml).unwrap();
        assert_eq!(feed.entries[0].url.as_deref(), Some("https://e/1"));
        assert_eq!(feed.entries[0].entry_id.as_deref(), Some("https://e/1"));
        assert_eq!(feed.entries[1].url, None);
        assert_eq!(feed.entries[1].entry_id.as_deref(), Some("x"));
    }

    #[test]
    fn atom_feed_url_and_entry_title() {
        let xml = r#"<feed xmlns="http://www.w3.org/2005/Atom"><title>A</title>
            <link href="https://e/feed" rel="self"/><link href="https://e/a"/><link href="https://e/b"/>
            <entry><title type="html">&lt;b&gt;x&lt;/b&gt;
              y</title><link href="https://e/1"/><id>i1</id><updated>2026-09-24T00:00:00Z</updated></entry>
        </feed>"#;
        let feed = parse_feed(xml).unwrap();
        assert_eq!(feed.url.as_deref(), Some("https://e/b"));
        assert_eq!(feed.links, vec!["https://e/feed", "https://e/a", "https://e/b"]);
        let e = &feed.entries[0];
        assert_eq!(e.title.as_deref(), Some("x y"));
        assert_eq!(e.url.as_deref(), Some("https://e/1"));
        assert!(e.published.is_some()); // published が無ければ updated
    }

    #[test]
    fn google_alerts_url_is_unwrapped_or_nil() {
        let xml = r#"<feed xmlns="http://www.w3.org/2005/Atom"><id>tag:google.com,2005:reader/user/1/state/com.google/alerts/2</id>
            <entry><link href="https://www.google.com/url?rct=j&amp;url=https://n.example/a&amp;ct=ga"/></entry>
            <entry><link href="https://n.example/b"/></entry></feed>"#;
        let feed = parse_feed(xml).unwrap();
        assert_eq!(feed.entries[0].url.as_deref(), Some("https://n.example/a"));
        assert_eq!(feed.entries[1].url, None);
    }

    #[test]
    fn itunes_item_enclosure_is_not_an_image() {
        let xml = r#"<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
            <itunes:image href="https://e/c.jpg"/>
            <item><enclosure url="https://e/1.mp3" type="audio/mpeg"/><itunes:subtitle>s</itunes:subtitle></item>
        </channel></rss>"#;
        let feed = parse_feed(xml).unwrap();
        assert_eq!(feed.itunes_image.as_deref(), Some("https://e/c.jpg"));
        let e = &feed.entries[0];
        assert!(e.is_itunes_item);
        assert_eq!(e.image, None);
        assert_eq!(e.enclosure_url.as_deref(), Some("https://e/1.mp3"));
        assert_eq!(e.enclosure_type.as_deref(), Some("audio/mpeg"));
        assert_eq!(e.itunes_subtitle.as_deref(), Some("s"));
    }

    #[test]
    fn unsupported_and_unknown() {
        assert!(matches!(parse_feed(r#"{"version":"https://jsonfeed.org/version/1"}"#), Err(ParseError::Unsupported(_))));
        assert!(matches!(parse_feed("<html/>"), Err(ParseError::NoParser)));
    }
}
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `cd fetcher && cargo test --lib parse`
Expected: コンパイルエラー

- [ ] **Step 3: 実装する**

`fetcher/src/parse/detect.rs`:

```rust
use std::sync::LazyLock;

use regex::Regex;

use crate::model::FeedFormat;

static CDATA: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<!\[CDATA\[.*?\]\]>").unwrap());
static ITUNES: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)xmlns:itunes\s?=\s?["']http://www\.itunes\.com/dtds/podcast-1\.0\.dtd["']"#).unwrap()
});
static RSS_OR_RDF: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<rss|<rdf").unwrap());
static GOOGLE_DOCS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<id>https?://docs\.google\.com/.*</id>").unwrap());
static ATOM: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"<feed[^>]+xmlns\s?=\s?["'](https?://www\.w3\.org/2005/Atom|http://purl\.org/atom/ns#)["'][^>]*>"#).unwrap()
});
static GOOGLE_ALERTS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<id>tag:google\.com,2005:[^<]+/com\.google/alerts/").unwrap());

/// Feedjira 4.0.2 の既定のパーサ順 (Feedjira::Configuration#default_parsers) と同じ判定をする。
pub fn detect_format(xml: &str) -> Option<FeedFormat> {
    let rss_or_rdf = RSS_OR_RDF.is_match(xml);
    let feedburner = xml.contains("feedburner");
    if ITUNES.is_match(&CDATA.replace_all(xml, "")) {
        return Some(FeedFormat::ItunesRss);
    }
    if rss_or_rdf && feedburner {
        return Some(FeedFormat::RssFeedburner);
    }
    if GOOGLE_DOCS.is_match(xml) {
        return Some(FeedFormat::GoogleDocsAtom);
    }
    if xml.contains(r#"xmlns:yt="http://www.youtube.com/xml/schemas/2015""#) {
        return Some(FeedFormat::AtomYoutube);
    }
    if xml.contains("<feed") && xml.contains("Atom") && feedburner && !rss_or_rdf {
        return Some(FeedFormat::AtomFeedburner);
    }
    let atom = ATOM.is_match(xml);
    if atom && GOOGLE_ALERTS.is_match(xml) {
        return Some(FeedFormat::AtomGoogleAlerts);
    }
    if atom {
        return Some(FeedFormat::Atom);
    }
    if rss_or_rdf && !feedburner {
        return Some(FeedFormat::Rss);
    }
    if xml.contains("https://jsonfeed.org/version/") || xml.contains(r"https:\/\/jsonfeed.org\/version\/") {
        return Some(FeedFormat::JsonFeed);
    }
    None
}
```

`fetcher/src/parse/classes.rs` (Feedjira 4.0.2 の各クラスの `element` / `elements` 宣言を、宣言順のまま写したもの。使わない値のルールも、文脈の切り替えと「最初の1回」の判定に効くものは残す。`include` で共有している宣言はマクロにまとめ、追加のルールを引数で受け取って1つの配列にする):

```rust
use super::sax::{Class, Cond::*, Rule::*, Setter::*};

const NO_ATTRS: &[(&str, &str)] = &[];

/// RSSImage / ITunesRSSOwner / ITunesRSSCategory / PodloveChapter の代わり。中の要素を吸収するだけ
pub static ABSORB: Class = Class { rules: &[], value_field: None, attr_fields: NO_ATTRS };

pub static GUID: Class = Class {
    rules: &[],
    value_field: Some("guid"),
    attr_fields: &[("isPermaLink", "is_perma_link")],
};

/// RSSEntryUtilities の宣言 (enclosure → image を除く) + 追加のルール
macro_rules! rss_entry_rules {
    ($($extra:expr),* $(,)?) => {
        &[
            Text { name: "title", with: &[], field: "title", setter: Plain },
            Text { name: "content:encoded", with: &[], field: "content", setter: Plain },
            Text { name: "a10:content", with: &[], field: "content", setter: Plain },
            Text { name: "description", with: &[], field: "summary", setter: Plain },
            Text { name: "link", with: &[], field: "url", setter: Plain },
            Attr { name: "a10:link", with: &[], attr: "href", field: "url", setter: Plain },
            Text { name: "author", with: &[], field: "author", setter: Plain },
            Text { name: "dc:creator", with: &[], field: "author", setter: Plain },
            Text { name: "a10:name", with: &[], field: "author", setter: Plain },
            Text { name: "pubDate", with: &[], field: "published", setter: KeepOldest },
            Text { name: "pubdate", with: &[], field: "published", setter: KeepOldest },
            Text { name: "issued", with: &[], field: "published", setter: KeepOldest },
            Text { name: "dc:date", with: &[], field: "published", setter: KeepOldest },
            Text { name: "dc:Date", with: &[], field: "published", setter: KeepOldest },
            Text { name: "dcterms:created", with: &[], field: "published", setter: KeepOldest },
            Text { name: "dcterms:modified", with: &[], field: "updated", setter: KeepNewest },
            Text { name: "a10:updated", with: &[], field: "updated", setter: KeepNewest },
            Child { name: "guid", with: &[], class: &GUID, field: "entry_id" },
            Text { name: "dc:identifier", with: &[], field: "dc_identifier", setter: Plain },
            Attr { name: "media:thumbnail", with: &[], attr: "url", field: "image", setter: Plain },
            Attr { name: "media:content", with: &[], attr: "url", field: "image", setter: Plain },
            Text { name: "comments", with: &[], field: "comments", setter: Plain },
            $($extra),*
        ]
    };
}

/// AtomEntryUtilities の宣言 (link を除く) + 追加のルール
macro_rules! atom_entry_rules {
    ($($extra:expr),* $(,)?) => {
        &[
            Text { name: "title", with: &[Eq("type", "html")], field: "raw_title", setter: Plain },
            Text { name: "title", with: &[Eq("type", "xhtml")], field: "raw_title", setter: Plain },
            Text { name: "title", with: &[Eq("type", "xml")], field: "raw_title", setter: Plain },
            Text { name: "title", with: &[Eq("type", "text")], field: "title", setter: Plain },
            Text { name: "title", with: &[Absent("type")], field: "title", setter: Plain },
            Attr { name: "title", with: &[], attr: "type", field: "title_type", setter: Plain },
            Text { name: "name", with: &[], field: "author", setter: Plain },
            Text { name: "content", with: &[], field: "content", setter: Plain },
            Text { name: "summary", with: &[], field: "summary", setter: Plain },
            Attr { name: "enclosure", with: &[], attr: "href", field: "image", setter: Plain },
            Text { name: "published", with: &[], field: "published", setter: KeepOldest },
            Text { name: "id", with: &[], field: "entry_id", setter: Plain },
            Text { name: "created", with: &[], field: "published", setter: KeepOldest },
            Text { name: "issued", with: &[], field: "published", setter: KeepOldest },
            Text { name: "updated", with: &[], field: "updated", setter: KeepNewest },
            Text { name: "modified", with: &[], field: "updated", setter: KeepNewest },
            $($extra),*
        ]
    };
}

/// RSS / RSSFeedBurner のフィード側の宣言。entries のクラスだけ違う
macro_rules! rss_feed_rules {
    ($entry:expr) => {
        &[
            Text { name: "description", with: &[], field: "description", setter: Plain },
            Child { name: "image", with: &[], class: &ABSORB, field: "image" },
            Text { name: "language", with: &[], field: "language", setter: Plain },
            Text { name: "lastBuildDate", with: &[], field: "last_built", setter: Plain },
            Text { name: "link", with: &[], field: "url", setter: Plain },
            Attr { name: "a10:link", with: &[], attr: "href", field: "url", setter: Plain },
            Text { name: "title", with: &[], field: "title", setter: Plain },
            Text { name: "ttl", with: &[], field: "ttl", setter: Plain },
            Collection { name: "item", class: $entry, field: "entries" },
        ]
    };
}

/// Atom / AtomGoogleAlerts / AtomFeedBurner のフィード側の宣言。entries のクラスだけ違う
macro_rules! atom_feed_rules {
    ($entry:expr) => {
        &[
            Text { name: "title", with: &[], field: "title", setter: Plain },
            Text { name: "subtitle", with: &[], field: "description", setter: Plain },
            Attr { name: "link", with: &[Eq("type", "text/html")], attr: "href", field: "url", setter: Plain },
            Attr { name: "link", with: &[Eq("rel", "self")], attr: "href", field: "feed_url", setter: Plain },
            Attr { name: "link", with: &[], attr: "href", field: "links", setter: Append },
            Collection { name: "entry", class: $entry, field: "entries" },
            Text { name: "icon", with: &[], field: "icon", setter: Plain },
        ]
    };
}

// ---- RSS ----

pub static RSS_ENTRY: Class = Class {
    rules: rss_entry_rules!(Attr { name: "enclosure", with: &[], attr: "url", field: "image", setter: Plain }),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static RSS: Class = Class { rules: rss_feed_rules!(&RSS_ENTRY), value_field: None, attr_fields: NO_ATTRS };

pub static RSS_FEEDBURNER_ENTRY: Class = Class {
    rules: rss_entry_rules!(
        Attr { name: "enclosure", with: &[], attr: "url", field: "image", setter: Plain },
        Text { name: "feedburner:origLink", with: &[], field: "orig_link", setter: Plain },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static RSS_FEEDBURNER: Class =
    Class { rules: rss_feed_rules!(&RSS_FEEDBURNER_ENTRY), value_field: None, attr_fields: NO_ATTRS };

// ---- iTunes ----

pub static ITUNES_ITEM: Class = Class {
    rules: rss_entry_rules!(
        Text { name: "itunes:author", with: &[], field: "itunes_author", setter: Plain },
        Text { name: "itunes:block", with: &[], field: "itunes_block", setter: Plain },
        Text { name: "itunes:duration", with: &[], field: "itunes_duration", setter: Plain },
        Text { name: "itunes:explicit", with: &[], field: "itunes_explicit", setter: Plain },
        Text { name: "itunes:keywords", with: &[], field: "itunes_keywords", setter: Plain },
        Text { name: "itunes:subtitle", with: &[], field: "itunes_subtitle", setter: Plain },
        Attr { name: "itunes:image", with: &[], attr: "href", field: "itunes_image", setter: Plain },
        Text { name: "itunes:isClosedCaptioned", with: &[], field: "itunes_closed_captioned", setter: Plain },
        Text { name: "itunes:order", with: &[], field: "itunes_order", setter: Plain },
        Text { name: "itunes:season", with: &[], field: "itunes_season", setter: Plain },
        Text { name: "itunes:episode", with: &[], field: "itunes_episode", setter: Plain },
        Text { name: "itunes:title", with: &[], field: "itunes_title", setter: Plain },
        Text { name: "itunes:episodeType", with: &[], field: "itunes_episode_type", setter: Plain },
        Text { name: "itunes:summary", with: &[], field: "itunes_summary", setter: Plain },
        Attr { name: "enclosure", with: &[], attr: "length", field: "enclosure_length", setter: Plain },
        Attr { name: "enclosure", with: &[], attr: "type", field: "enclosure_type", setter: Plain },
        Attr { name: "enclosure", with: &[], attr: "url", field: "enclosure_url", setter: Plain },
        Collection { name: "psc:chapter", class: &ABSORB, field: "raw_chapters" },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static ITUNES: Class = Class {
    rules: &[
        Text { name: "copyright", with: &[], field: "copyright", setter: Plain },
        Text { name: "description", with: &[], field: "description", setter: Plain },
        Child { name: "image", with: &[], class: &ABSORB, field: "image" },
        Text { name: "language", with: &[], field: "language", setter: Plain },
        Text { name: "lastBuildDate", with: &[], field: "last_built", setter: Plain },
        Text { name: "link", with: &[], field: "url", setter: Plain },
        Text { name: "managingEditor", with: &[], field: "managing_editor", setter: Plain },
        Text { name: "title", with: &[], field: "title", setter: Plain },
        Text { name: "ttl", with: &[], field: "ttl", setter: Plain },
        Text { name: "itunes:author", with: &[], field: "itunes_author", setter: Plain },
        Text { name: "itunes:block", with: &[], field: "itunes_block", setter: Plain },
        Attr { name: "itunes:image", with: &[], attr: "href", field: "itunes_image", setter: Plain },
        Text { name: "itunes:explicit", with: &[], field: "itunes_explicit", setter: Plain },
        Text { name: "itunes:complete", with: &[], field: "itunes_complete", setter: Plain },
        Text { name: "itunes:keywords", with: &[], field: "itunes_keywords", setter: Plain },
        Text { name: "itunes:type", with: &[], field: "itunes_type", setter: Plain },
        Text { name: "itunes:new_feed_url", with: &[], field: "itunes_new_feed_url", setter: Plain },
        Text { name: "itunes:subtitle", with: &[], field: "itunes_subtitle", setter: Plain },
        Text { name: "itunes:summary", with: &[], field: "itunes_summary", setter: Plain },
        Collection { name: "itunes:category", class: &ABSORB, field: "itunes_categories" },
        Collection { name: "itunes:owner", class: &ABSORB, field: "itunes_owners" },
        Collection { name: "item", class: &ITUNES_ITEM, field: "entries" },
    ],
    value_field: None,
    attr_fields: NO_ATTRS,
};

// ---- Atom ----

pub static ATOM_ENTRY: Class = Class {
    rules: atom_entry_rules!(
        Attr { name: "link", with: &[Eq("type", "text/html"), Eq("rel", "alternate")], attr: "href", field: "url", setter: Plain },
        Attr { name: "link", with: &[], attr: "href", field: "links", setter: Append },
        Attr { name: "media:thumbnail", with: &[], attr: "url", field: "image", setter: Plain },
        Attr { name: "media:content", with: &[], attr: "url", field: "image", setter: Plain },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static ATOM: Class = Class { rules: atom_feed_rules!(&ATOM_ENTRY), value_field: None, attr_fields: NO_ATTRS };

pub static GOOGLE_ALERTS_ENTRY: Class = Class {
    rules: atom_entry_rules!(
        Attr { name: "link", with: &[Eq("type", "text/html"), Eq("rel", "alternate")], attr: "href", field: "url", setter: Plain },
        Attr { name: "link", with: &[], attr: "href", field: "links", setter: Append },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static GOOGLE_ALERTS: Class =
    Class { rules: atom_feed_rules!(&GOOGLE_ALERTS_ENTRY), value_field: None, attr_fields: NO_ATTRS };

pub static ATOM_FEEDBURNER_ENTRY: Class = Class {
    rules: atom_entry_rules!(
        Attr { name: "link", with: &[Eq("type", "text/html"), Eq("rel", "alternate")], attr: "href", field: "url", setter: Plain },
        Attr { name: "link", with: &[], attr: "href", field: "links", setter: Append },
        Attr { name: "media:thumbnail", with: &[], attr: "url", field: "image", setter: Plain },
        Attr { name: "media:content", with: &[], attr: "url", field: "image", setter: Plain },
        Text { name: "feedburner:origLink", with: &[], field: "orig_link", setter: Plain },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static ATOM_FEEDBURNER: Class =
    Class { rules: atom_feed_rules!(&ATOM_FEEDBURNER_ENTRY), value_field: None, attr_fields: NO_ATTRS };

// ---- YouTube ----

pub static YOUTUBE_ENTRY: Class = Class {
    // AtomYoutubeEntry は AtomEntryUtilities の link の宣言を消して、rel=alternate の link だけを持つ
    rules: atom_entry_rules!(
        Attr { name: "link", with: &[Eq("rel", "alternate")], attr: "href", field: "url", setter: Plain },
        Text { name: "media:description", with: &[], field: "content", setter: Plain },
        Text { name: "yt:videoId", with: &[], field: "youtube_video_id", setter: Plain },
        Text { name: "yt:channelId", with: &[], field: "youtube_channel_id", setter: Plain },
        Text { name: "media:title", with: &[], field: "media_title", setter: Plain },
        Attr { name: "media:content", with: &[], attr: "url", field: "media_url", setter: Plain },
        Attr { name: "media:thumbnail", with: &[], attr: "url", field: "media_thumbnail_url", setter: Plain },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static YOUTUBE: Class = Class {
    rules: &[
        Text { name: "title", with: &[], field: "title", setter: Plain },
        Attr { name: "link", with: &[Eq("rel", "alternate")], attr: "href", field: "url", setter: Plain },
        Attr { name: "link", with: &[Eq("rel", "self")], attr: "href", field: "feed_url", setter: Plain },
        Text { name: "name", with: &[], field: "author", setter: Plain },
        Text { name: "yt:channelId", with: &[], field: "youtube_channel_id", setter: Plain },
        Collection { name: "entry", class: &YOUTUBE_ENTRY, field: "entries" },
    ],
    value_field: None,
    attr_fields: NO_ATTRS,
};
```

このファイルで Feedjira のソースを読まずに写した (推定の) ものは、`GOOGLE_ALERTS` のフィード側、`RSS_FEEDBURNER*`、`ATOM_FEEDBURNER*` の3つ。Step 3 の最後に次のコマンドで宣言を確かめ、違っていれば合わせる。

```bash
docker compose run --rm web bash -c 'd=$(bundle show feedjira)/lib/feedjira/parser; cat $d/atom_google_alerts.rb $d/rss_feed_burner.rb $d/rss_feed_burner_entry.rb $d/atom_feed_burner.rb $d/atom_feed_burner_entry.rb'
```

特に FeedBurner の entry の `url` の決め方 (`orig_link || super` なのか別の規則なのか) は、`extract.rs` の `FeedFormat::RssFeedburner` / `AtomFeedburner` の分岐に反映する。

`fetcher/src/parse/extract.rs`:

```rust
use chrono::{DateTime, Utc};
use scraper::Html;

use super::classes;
use super::date::parse_datetime;
use super::detect::detect_format;
use super::sax::{parse, Class, Obj};
use crate::model::FeedFormat;

#[derive(Debug, Clone, Default)]
pub struct RawEntry {
    pub title: Option<String>,
    pub url: Option<String>,
    pub entry_id: Option<String>,
    pub published: Option<DateTime<Utc>>,
    pub summary: Option<String>,
    pub itunes_subtitle: Option<String>,
    pub itunes_image: Option<String>,
    pub image: Option<String>,
    pub enclosure_url: Option<String>,
    pub enclosure_type: Option<String>,
    pub is_itunes_item: bool,
}

#[derive(Debug, Clone)]
pub struct RawFeed {
    pub format: FeedFormat,
    pub title: Option<String>,
    pub description: Option<String>,
    pub url: Option<String>,
    pub links: Vec<String>,
    pub itunes_image: Option<String>,
    pub entries: Vec<RawEntry>,
}

#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("no parser available")]
    NoParser,
    #[error("unsupported format: {0:?}")]
    Unsupported(FeedFormat),
}

fn class_for(format: FeedFormat) -> Option<&'static Class> {
    Some(match format {
        FeedFormat::ItunesRss => &classes::ITUNES,
        FeedFormat::RssFeedburner => &classes::RSS_FEEDBURNER,
        FeedFormat::AtomYoutube => &classes::YOUTUBE,
        FeedFormat::AtomFeedburner => &classes::ATOM_FEEDBURNER,
        FeedFormat::AtomGoogleAlerts => &classes::GOOGLE_ALERTS,
        FeedFormat::Atom => &classes::ATOM,
        FeedFormat::Rss => &classes::RSS,
        FeedFormat::GoogleDocsAtom | FeedFormat::JsonFeed => return None,
    })
}

fn owned(v: Option<&str>) -> Option<String> {
    v.map(str::to_string)
}

/// Loofah.fragment(s).xpath("normalize-space(.)") の近似
fn html_normalize_space(s: &str) -> String {
    let text: String = Html::parse_fragment(s).root_element().text().collect();
    text.split([' ', '\t', '\n', '\r']).filter(|p| !p.is_empty()).collect::<Vec<_>>().join(" ")
}

fn published(obj: &Obj) -> Option<DateTime<Utc>> {
    obj.get("published").or(obj.get("updated")).and_then(parse_datetime)
}

fn rss_entry(obj: &Obj, is_itunes_item: bool) -> RawEntry {
    let guid = obj.child("entry_id");
    let entry_id = guid.and_then(|g| g.get("guid"));
    let perma_link = guid.map(|g| g.get("is_perma_link") != Some("false")).unwrap_or(false);
    let url = owned(obj.get("url")).or_else(|| if perma_link { owned(entry_id) } else { None });
    RawEntry {
        title: owned(obj.get("title")),
        url,
        entry_id: owned(entry_id),
        published: published(obj),
        summary: owned(obj.get("summary")),
        itunes_subtitle: owned(obj.get("itunes_subtitle")),
        itunes_image: owned(obj.get("itunes_image")),
        image: owned(obj.get("image")),
        enclosure_url: owned(obj.get("enclosure_url")),
        enclosure_type: owned(obj.get("enclosure_type")),
        is_itunes_item,
    }
}

fn atom_entry(obj: &Obj) -> RawEntry {
    let title = owned(obj.get("title")).or_else(|| obj.get("raw_title").map(html_normalize_space));
    let url = owned(obj.get("url")).or_else(|| obj.all("links").first().cloned());
    RawEntry {
        title,
        url,
        entry_id: owned(obj.get("entry_id")),
        published: published(obj),
        summary: owned(obj.get("summary")),
        image: owned(obj.get("image")),
        ..RawEntry::default()
    }
}

fn unwrap_google_url(url: Option<String>) -> Option<String> {
    let url = url?;
    if !url.starts_with("https://www.google.com/url?") {
        return None;
    }
    let parsed = url::Url::parse(&url).ok()?;
    parsed.query_pairs().find(|(k, _)| k == "url").map(|(_, v)| v.into_owned())
}

pub fn parse_feed(xml: &str) -> Result<RawFeed, ParseError> {
    let format = detect_format(xml).ok_or(ParseError::NoParser)?;
    let class = class_for(format).ok_or(ParseError::Unsupported(format))?;
    let root = parse(xml, class);

    let entries = root
        .list("entries")
        .iter()
        .map(|e| match format {
            FeedFormat::Rss => rss_entry(e, false),
            FeedFormat::ItunesRss => rss_entry(e, true),
            FeedFormat::RssFeedburner => {
                let mut entry = rss_entry(e, false);
                entry.url = owned(e.get("orig_link")).or(entry.url);
                entry
            }
            FeedFormat::AtomFeedburner => {
                let mut entry = atom_entry(e);
                entry.url = owned(e.get("orig_link")).or(entry.url);
                entry
            }
            FeedFormat::AtomGoogleAlerts => {
                let mut entry = atom_entry(e);
                entry.url = unwrap_google_url(entry.url);
                entry
            }
            _ => atom_entry(e),
        })
        .collect();

    let links = root.all("links").to_vec();
    let url = match format {
        FeedFormat::Atom | FeedFormat::AtomGoogleAlerts | FeedFormat::AtomFeedburner => {
            let feed_url = root.get("feed_url");
            owned(root.get("url"))
                .or_else(|| links.iter().filter(|l| Some(l.as_str()) != feed_url).last().cloned())
        }
        _ => owned(root.get("url")),
    };

    Ok(RawFeed {
        format,
        title: owned(root.get("title")),
        description: owned(root.get("description")),
        url,
        links,
        itunes_image: owned(root.get("itunes_image")),
        entries,
    })
}
```

`fetcher/src/parse/mod.rs`:

```rust
pub mod classes;
pub mod date;
pub mod detect;
pub mod extract;
pub mod sax;
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `cd fetcher && cargo test --lib parse`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add fetcher/src
git commit -m "fetcherにフィード形式の判別とFeedjira互換のクラス定義を追加"
```

---

### Task 6: 相対 URL の解決・チャンネル情報・entry の整形 (golden を通す)

**Files:**
- Modify: `fetcher/src/filters/relative_url_resolver.rs`
- Create: `fetcher/src/shape/mod.rs`, `fetcher/src/shape/channel.rs`, `fetcher/src/shape/entry.rs`
- Modify: `fetcher/src/lib.rs` (`pub mod shape;`、`golden_output` の実装、`prepare`)
- Modify: `fetcher/tests/golden.rs` (`#[ignore]` を外す)

**Interfaces:**
- Consumes: `parse::extract::{parse_feed, RawFeed, RawEntry, ParseError}`、`filters::apply_pre_parse`、`encoding::to_utf8_dropping_invalid`、`ruby::*`
- Produces (`filters/relative_url_resolver.rs`):
  - `fn apply(feed: &mut RawFeed, feed_url: &str) -> Option<serde_json::Value>` (適用したら details)
  - `fn resolve_like_rails(url: &str, feed_url: &str) -> String` (`Channel.normalize_url` と RelativeUrlResolver が共有する、`scheme://host[:port]` 基準の解決)
- Produces (`lib.rs`):

```rust
pub struct Prepared {
    pub feed: RawFeed,
    pub applied_filters: Vec<String>,
    pub filter_details: serde_json::Map<String, serde_json::Value>,
}
pub fn prepare(body: &[u8], feed_url: &str) -> Result<Prepared, ParseError>
pub fn golden_output(body: &[u8], feed_url: &str) -> anyhow::Result<ShapedFeed>
```

- Produces (`shape/channel.rs`):
  - `struct Ogp { pub title: Option<String>, pub description: Option<String>, pub image: Option<String> }`
  - `fn ogp_target(feed: &RawFeed, feed_url: &str) -> Option<String>` (チャンネル情報のために OGP を取りに行く URL。iTunes と未対応形式は None)
  - `fn channel_meta(feed: &RawFeed, feed_url: &str, ogp: Option<&Ogp>) -> Option<ChannelMeta>` (Channel のバリデーションに通らなければ None)
- Produces (`shape/entry.rs`):

```rust
pub enum ImageCandidate { Direct(String), NeedsOgp }
pub struct EntryDraft {
    pub raw_entry_id: Option<String>,   // new-guids の判定に使う (Rails の exists?(guid: entry_id))
    pub raw_url: Option<String>,        // 同上 (exists?(guid: url))
    pub guid: String,
    pub title_raw: Option<String>,
    pub url: String,                    // エンコード済み
    pub published: Option<DateTime<Utc>>,
    pub image: ImageCandidate,
    pub data: EntryData,
    pub data_extra: DataExtra,          // items.data の残り4キー (entry_id, title, url, published)
}
pub struct DataExtra { pub entry_id: Option<String>, pub title: Option<String>, pub url: Option<String>, pub published: Option<String> }
pub fn draft_entries(feed: &RawFeed, site_url: Option<&str>) -> (Vec<EntryDraft>, Vec<Skipped>)
pub fn finalize_entries(drafts: Vec<(EntryDraft, Option<String>, bool)>) -> (Vec<ShapedEntry>, Vec<Skipped>)
    // タプルは (draft, OGP で取れた画像, OGP を取らずに済ませたか)
```

- [ ] **Step 1: 失敗するテストを書く**

`fetcher/tests/golden.rs` の `#[ignore = "Task 6 で有効にする"]` の行を消す。

`fetcher/src/filters/relative_url_resolver.rs` のテスト (Ruby の `relative_url_resolver_test.rb` の観点を移植):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::FeedFormat;
    use crate::parse::extract::{RawEntry, RawFeed};

    fn feed(url: Option<&str>, entry_urls: &[&str]) -> RawFeed {
        RawFeed {
            format: FeedFormat::Rss,
            title: None,
            description: None,
            url: url.map(str::to_string),
            links: vec![],
            itunes_image: None,
            entries: entry_urls
                .iter()
                .map(|u| RawEntry { url: Some(u.to_string()), ..RawEntry::default() })
                .collect(),
        }
    }

    #[test]
    fn resolves_against_scheme_and_host_only() {
        let mut f = feed(Some("/"), &["/post/1", "post/2", "http://example.com/post/3"]);
        let details = apply(&mut f, "http://example.com/blog/feed.xml").unwrap();
        assert_eq!(f.url.as_deref(), Some("http://example.com/"));
        assert_eq!(f.entries[0].url.as_deref(), Some("http://example.com/post/1"));
        assert_eq!(f.entries[1].url.as_deref(), Some("http://example.com/post/2"));
        assert_eq!(f.entries[2].url.as_deref(), Some("http://example.com/post/3"));
        assert_eq!(details["converted_count"], 3);
        assert_eq!(details["base_url"], "http://example.com");
    }

    #[test]
    fn keeps_non_default_port() {
        let mut f = feed(None, &["/a"]);
        apply(&mut f, "https://example.com:8080/feed.xml").unwrap();
        assert_eq!(f.entries[0].url.as_deref(), Some("https://example.com:8080/a"));
    }

    #[test]
    fn not_applied_when_all_absolute() {
        let mut f = feed(Some("https://example.com/"), &["https://example.com/1"]);
        assert!(apply(&mut f, "https://example.com/feed.xml").is_none());
    }
}
```

`fetcher/src/shape/entry.rs` のテスト:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_multibyte_chars_and_double_quotes_only() {
        assert_eq!(encode_url_like_rails("https://e/日本?q=\"x\" y"), "https://e/%E6%97%A5%E6%9C%AC?q=%22x%22 y");
    }
}
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `cd fetcher && cargo test`
Expected: FAIL (golden テストが `unimplemented` で panic、新しい単体テストはコンパイルエラー)

- [ ] **Step 3: 相対 URL の解決を実装する**

`fetcher/src/filters/relative_url_resolver.rs`:

```rust
//! RelativeUrlResolver と Channel.normalize_url の再現。
//! Ruby 版と同じく、フィードのディレクトリではなく scheme://host[:port] を基準に解決する。

use serde_json::json;

use crate::parse::extract::RawFeed;
use crate::ruby::is_blank;

fn has_relative_url(url: Option<&str>) -> bool {
    match url {
        None => false,
        Some(u) if is_blank(u) => false,
        Some(u) => u.starts_with('/') || !(u.starts_with("http://") || u.starts_with("https://")),
    }
}

pub fn base_url(feed_url: &str) -> Option<String> {
    let parsed = url::Url::parse(feed_url).ok()?;
    let host = parsed.host_str()?;
    let port = parsed.port().map(|p| format!(":{p}")).unwrap_or_default();
    Some(format!("{}://{}{}", parsed.scheme(), host, port))
}

pub fn resolve_like_rails(url: &str, feed_url: &str) -> String {
    if url.starts_with("http://") || url.starts_with("https://") {
        return url.to_string();
    }
    let Some(base) = base_url(feed_url) else { return url.to_string() };
    if url.starts_with('/') {
        return format!("{base}{url}");
    }
    url::Url::parse(&format!("{base}/"))
        .and_then(|b| b.join(url))
        .map(|u| u.to_string())
        .unwrap_or_else(|_| url.to_string())
}

pub fn apply(feed: &mut RawFeed, feed_url: &str) -> Option<serde_json::Value> {
    let applicable = has_relative_url(feed.url.as_deref())
        || feed.entries.iter().any(|e| has_relative_url(e.url.as_deref()));
    if !applicable {
        return None;
    }

    let mut converted = Vec::new();
    if has_relative_url(feed.url.as_deref()) {
        let from = feed.url.clone().unwrap();
        let to = resolve_like_rails(&from, feed_url);
        converted.push(json!({ "from": from, "to": to, "target": "feed" }));
        feed.url = Some(to);
    }
    for entry in &mut feed.entries {
        if has_relative_url(entry.url.as_deref()) {
            let from = entry.url.clone().unwrap();
            let to = resolve_like_rails(&from, feed_url);
            converted.push(json!({ "from": from, "to": to, "target": "entry" }));
            entry.url = Some(to);
        }
    }

    let count = converted.len();
    Some(json!({
        "base_url": base_url(feed_url),
        "converted_count": count,
        "sample_urls": converted.into_iter().take(5).collect::<Vec<_>>(),
        "has_more": count > 5,
    }))
}
```

- [ ] **Step 4: チャンネル情報を実装する**

`fetcher/src/shape/channel.rs`:

```rust
//! Channel.build_from_* とチャンネルのバリデーション・コールバックの再現。

use crate::filters::relative_url_resolver::resolve_like_rails;
use crate::model::{ChannelMeta, FeedFormat};
use crate::parse::extract::RawFeed;
use crate::ruby::{is_blank, ruby_strip, valid_url_column};

#[derive(Debug, Clone, Default)]
pub struct Ogp {
    pub title: Option<String>,
    pub description: Option<String>,
    pub image: Option<String>,
}

/// Channel.normalize_url
pub fn normalize_site_url(url: Option<&str>, feed_url: &str) -> String {
    match url {
        None => feed_url.to_string(),
        Some(u) if is_blank(u) => feed_url.to_string(),
        Some(u) => resolve_like_rails(u, feed_url),
    }
}

pub fn ogp_target(feed: &RawFeed, feed_url: &str) -> Option<String> {
    match feed.format {
        FeedFormat::Rss | FeedFormat::Atom | FeedFormat::AtomGoogleAlerts | FeedFormat::AtomYoutube => {
            Some(normalize_site_url(feed.url.as_deref(), feed_url))
        }
        _ => None,
    }
}

fn blank_to_none(v: Option<String>) -> Option<String> {
    v.filter(|s| !is_blank(s))
}

pub fn channel_meta(feed: &RawFeed, feed_url: &str, ogp: Option<&Ogp>) -> Option<ChannelMeta> {
    let site_url = normalize_site_url(feed.url.as_deref(), feed_url);
    let (description, site_url, image_url) = match feed.format {
        FeedFormat::Rss => (feed.description.clone(), Some(site_url), ogp.and_then(|o| o.image.clone())),
        FeedFormat::Atom | FeedFormat::AtomGoogleAlerts => (
            feed.description.clone(),
            Some(feed.links.first().cloned().unwrap_or(site_url)),
            ogp.and_then(|o| o.image.clone()),
        ),
        FeedFormat::ItunesRss => (feed.description.clone(), Some(site_url), feed.itunes_image.clone()),
        FeedFormat::AtomYoutube => (
            ogp.and_then(|o| o.description.clone()),
            Some(site_url),
            ogp.and_then(|o| o.image.clone()),
        ),
        _ => return None,
    };

    // before_validation: 空文字を nil に
    let description = blank_to_none(description);
    let site_url = blank_to_none(site_url);
    let image_url = blank_to_none(image_url);
    let title = feed.title.clone();

    // validation (strip 前の値で行う)
    let title_ok = title.as_deref().is_some_and(|t| !is_blank(t) && t.chars().count() <= 256);
    let description_ok = description.as_deref().is_none_or(|d| d.chars().count() <= 1400);
    let urls_ok = [&site_url, &image_url].iter().all(|u| u.as_deref().is_none_or(valid_url_column));
    if !(title_ok && description_ok && urls_ok) {
        return None;
    }

    // before_save: strip
    Some(ChannelMeta {
        title: title.map(|t| ruby_strip(&t).to_string()),
        description: description.map(|d| ruby_strip(&d).to_string()),
        site_url,
        image_url,
    })
}
```

- [ ] **Step 5: entry の整形を実装する**

`fetcher/src/shape/entry.rs`:

```rust
//! Channel#fetch_and_save_items と Item のバリデーション・コールバックの再現。

use std::collections::HashMap;

use chrono::{DateTime, Utc};

use crate::model::{EntryData, ShapedEntry, SkipReason, Skipped};
use crate::parse::extract::RawFeed;
use crate::ruby::{is_blank, matches_uri_http, opt_presence, ruby_strip, valid_url_column};

#[derive(Debug, Clone, PartialEq)]
pub enum ImageCandidate {
    Direct(String),
    NeedsOgp,
}

#[derive(Debug, Clone, Default, PartialEq, serde::Serialize)]
pub struct DataExtra {
    pub entry_id: Option<String>,
    pub title: Option<String>,
    pub url: Option<String>,
    pub published: Option<String>,
}

#[derive(Debug, Clone)]
pub struct EntryDraft {
    pub raw_entry_id: Option<String>,
    pub raw_url: Option<String>,
    pub guid: String,
    pub title_raw: Option<String>,
    pub url: String,
    pub published: Option<DateTime<Utc>>,
    pub image: ImageCandidate,
    pub data: EntryData,
    pub data_extra: DataExtra,
}

/// マルチバイト文字と `"` だけをパーセントエンコードする (Rails と同じ)
pub fn encode_url_like_rails(url: &str) -> String {
    let mut out = String::with_capacity(url.len());
    for c in url.chars() {
        if c.len_utf8() > 1 {
            let mut buf = [0u8; 4];
            for b in c.encode_utf8(&mut buf).bytes() {
                out.push_str(&format!("%{b:02X}"));
            }
        } else if c == '"' {
            out.push_str("%22");
        } else {
            out.push(c);
        }
    }
    out
}

pub fn draft_entries(feed: &RawFeed, site_url: Option<&str>) -> (Vec<EntryDraft>, Vec<Skipped>) {
    let mut entries: Vec<_> = feed.entries.iter().collect();
    entries.sort_by_key(|e| e.published.unwrap_or(DateTime::<Utc>::UNIX_EPOCH));

    let mut drafts = Vec::new();
    let mut skipped = Vec::new();
    for entry in entries {
        let url = opt_presence(entry.url.as_deref())
            .or_else(|| if entry.is_itunes_item { opt_presence(entry.enclosure_url.as_deref()) } else { None })
            .or_else(|| opt_presence(site_url));
        let Some(url) = url else {
            skipped.push(Skipped { title: entry.title.clone(), reason: SkipReason::NoUrl });
            continue;
        };
        let encoded = encode_url_like_rails(ruby_strip(url));

        let Some(guid) = entry.entry_id.clone().or_else(|| entry.url.clone()) else {
            skipped.push(Skipped { title: entry.title.clone(), reason: SkipReason::NoGuid });
            continue;
        };

        let image = if let Some(img) = entry.itunes_image.clone().filter(|_| entry.is_itunes_item) {
            ImageCandidate::Direct(img)
        } else if let Some(img) = entry.image.clone() {
            ImageCandidate::Direct(img)
        } else if let Some(id) = guid.strip_prefix("yt:video:") {
            ImageCandidate::Direct(format!("https://img.youtube.com/vi/{id}/maxresdefault.jpg"))
        } else {
            ImageCandidate::NeedsOgp
        };

        drafts.push(EntryDraft {
            raw_entry_id: entry.entry_id.clone(),
            raw_url: entry.url.clone(),
            guid,
            title_raw: entry.title.clone(),
            url: encoded,
            published: entry.published,
            image,
            data: EntryData {
                summary: entry.summary.clone(),
                itunes_subtitle: entry.itunes_subtitle.clone(),
                enclosure_url: entry.enclosure_url.clone(),
                enclosure_type: entry.enclosure_type.clone(),
            },
            data_extra: DataExtra {
                entry_id: entry.entry_id.clone(),
                title: entry.title.clone(),
                url: entry.url.clone(),
                published: entry.published.map(|p| p.to_rfc3339()),
            },
        });
    }
    (drafts, skipped)
}

/// 画像を確定させ、Item のコールバックとバリデーションを当てる。
/// 同じ guid が複数あれば、後に処理したもので上書きする (find_or_initialize_by + update!)。
pub fn finalize_entries(drafts: Vec<(EntryDraft, Option<String>, bool)>) -> (Vec<ShapedEntry>, Vec<Skipped>) {
    let mut by_guid: HashMap<String, ShapedEntry> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut skipped = Vec::new();

    for (draft, ogp_image, pending) in drafts {
        let image = match draft.image {
            ImageCandidate::Direct(i) => Some(i),
            ImageCandidate::NeedsOgp => ogp_image,
        };
        // 不正な image_url は nil に落とす
        let image = image.filter(|i| is_blank(i) || matches_uri_http(i));
        // before_validation: 空文字を nil に、タイトルが空なら 〓
        let image = image.filter(|i| !is_blank(i));
        let title = match draft.title_raw {
            Some(t) if !is_blank(&t) => t,
            _ => "〓".to_string(),
        };

        let valid = title.chars().count() <= 256
            && !is_blank(&draft.guid)
            && draft.guid.chars().count() <= 2083
            && !is_blank(&draft.url)
            && valid_url_column(&draft.url)
            && image.as_deref().is_none_or(valid_url_column)
            && draft.published.is_some();
        if !valid {
            skipped.push(Skipped { title: draft.title_raw, reason: SkipReason::ValidationFailed });
            continue;
        }

        // before_save: strip
        let shaped = ShapedEntry {
            guid: draft.guid.clone(),
            title: ruby_strip(&title).to_string(),
            url: draft.url,
            image_url: image.map(|i| ruby_strip(&i).to_string()),
            published_at: draft.published.unwrap().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            data: draft.data,
            image_pending_ogp: pending,
        };
        if !by_guid.contains_key(&draft.guid) {
            order.push(draft.guid.clone());
        }
        by_guid.insert(draft.guid, shaped);
    }

    let entries = order.into_iter().filter_map(|g| by_guid.remove(&g)).collect();
    (entries, skipped)
}
```

`fetcher/src/shape/mod.rs`:

```rust
pub mod channel;
pub mod entry;
```

- [ ] **Step 6: `prepare` と `golden_output` を実装する**

`fetcher/src/lib.rs` を次の内容にする:

```rust
pub mod encoding;
pub mod filters;
pub mod model;
pub mod parse;
pub mod ruby;
pub mod shape;

use model::ShapedFeed;
use parse::extract::{parse_feed, ParseError, RawFeed};
use serde_json::{Map, Value};

pub struct Prepared {
    pub feed: RawFeed,
    pub applied_filters: Vec<String>,
    pub filter_details: Map<String, Value>,
}

/// 文字コードの修正 → パース前フィルタ → パース → パース後フィルタ (FeedNormalizer と同じ流れ)
pub fn prepare(body: &[u8], feed_url: &str) -> Result<Prepared, ParseError> {
    let xml = encoding::to_utf8_dropping_invalid(body);
    let (xml, mut applied, mut details) = filters::apply_pre_parse(xml);
    let mut feed = parse_feed(&xml)?;
    if let Some(detail) = filters::relative_url_resolver::apply(&mut feed, feed_url) {
        applied.push("RelativeUrlResolver".to_string());
        details.insert("RelativeUrlResolver".to_string(), detail);
    }
    Ok(Prepared { feed, applied_filters: applied, filter_details: details })
}

/// HTTP を使わずに、Rails の取り込みと同じ規則で整形する (OGP は取れなかった扱い)。
pub fn golden_output(body: &[u8], feed_url: &str) -> anyhow::Result<ShapedFeed> {
    let prepared = prepare(body, feed_url)?;
    let channel = shape::channel::channel_meta(&prepared.feed, feed_url, None);
    let site_url = channel.as_ref().and_then(|c| c.site_url.clone());
    let (drafts, mut skipped) = shape::entry::draft_entries(&prepared.feed, site_url.as_deref());
    let (entries, more_skipped) =
        shape::entry::finalize_entries(drafts.into_iter().map(|d| (d, None, false)).collect());
    skipped.extend(more_skipped);

    let mut out = ShapedFeed {
        format: prepared.feed.format,
        channel,
        applied_filters: prepared.applied_filters,
        entries,
        skipped,
    };
    out.normalize_order();
    Ok(out)
}
```

- [ ] **Step 7: golden が通るまで直す**

Run: `cd fetcher && cargo test`
Expected: 全件 PASS

差分が出たときは、golden (= Rails の実際の挙動) を正として Rust 側を直す。Rails の挙動のほうがバグに見えても、この計画では合わせる (spec の「移行を終えてから別途直す」方針)。直した内容と理由はコミットメッセージに残す。

- [ ] **Step 8: コミット**

```bash
git add fetcher/src fetcher/tests
git commit -m "fetcherでRailsと同じ規則のチャンネル情報とentryの整形を実装しgoldenを通す"
```

---

### Task 7: HTTP クライアントとホストごとの門番

**Files:**
- Create: `fetcher/src/http/mod.rs`, `fetcher/src/http/host_gate.rs`
- Modify: `fetcher/src/lib.rs` (`pub mod http;`)

**Interfaces:**
- Produces (`http/host_gate.rs`):
  - `struct HostGate` (`HostGate::new(min_interval: Duration)`)
  - `async fn acquire(&self, host: &str) -> HostPermit` (同じホストは同時に1つだけ。前回の解放から `min_interval` 経つまで待つ。`HostPermit` を drop すると解放)
- Produces (`http/mod.rs`):

```rust
pub struct HttpConfig { pub user_agent: String, pub connect_timeout: Duration, pub total_timeout: Duration, pub proxy: Option<ProxyConfig>, pub min_host_interval: Duration }
pub struct ProxyConfig { pub url: String, pub secret: String }
pub struct FetchResponse { pub body: Vec<u8>, pub final_url: String, pub redirected: bool, pub via_proxy: bool, pub register_proxy_domain: bool }
#[derive(Debug, thiserror::Error)]
pub enum FetchError { Status(u16), Timeout, Connect(String), TooManyRedirects, Other(String) }
impl FetchError { pub fn kind(&self) -> &'static str }  // "http_status" | "timeout" | "connect" | "too_many_redirects" | "other"
pub struct HttpClient
impl HttpClient {
    pub fn new(config: HttpConfig) -> anyhow::Result<Self>;
    /// Httpc.get_with_redirect_info 相当 (フィード用。403 でも proxy で再試行)
    pub async fn get_feed(&self, url: &str, use_proxy: bool) -> Result<FetchResponse, FetchError>;
    /// Httpc.get 相当 (OGP 用。proxy が要るドメインかどうかは呼び出し側が渡す。403 では再試行しない)
    pub async fn get_page(&self, url: &str, use_proxy: bool) -> Result<FetchResponse, FetchError>;
}
```

- 直接取得は、リダイレクトを自前で追う (最大3回。4回目で `TooManyRedirects`)。Cookie は1回の取得の中だけで引き継ぐ (Faraday で毎回新しい cookie_jar を作っているのと同じ)
- proxy へのリクエストは `GET {proxy.url}/`、ヘッダは `X-Proxy-Secret` と `X-Target-URL`。最終 URL はレスポンスヘッダ `X-Original-URL`。proxy 経由は門番を通さない (proxy 側が別の IP から取るため)
- 直接取得が接続失敗・タイムアウト (フィードは 403 も) のとき、proxy 設定があれば proxy で再試行し、2xx なら `register_proxy_domain: true`

- [ ] **Step 1: 失敗するテストを書く**

`fetcher/src/http/host_gate.rs` のテスト:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::time::Instant;

    #[tokio::test]
    async fn same_host_is_serialized_with_interval() {
        let gate = Arc::new(HostGate::new(Duration::from_millis(200)));
        let active = Arc::new(AtomicUsize::new(0));
        let start = Instant::now();
        let mut handles = Vec::new();
        for _ in 0..3 {
            let gate = gate.clone();
            let active = active.clone();
            handles.push(tokio::spawn(async move {
                let _permit = gate.acquire("example.com").await;
                assert_eq!(active.fetch_add(1, Ordering::SeqCst), 0, "同じホストに同時アクセスしている");
                tokio::time::sleep(Duration::from_millis(10)).await;
                active.fetch_sub(1, Ordering::SeqCst);
            }));
        }
        for h in handles {
            h.await.unwrap();
        }
        assert!(start.elapsed() >= Duration::from_millis(400));
    }

    #[tokio::test]
    async fn different_hosts_do_not_wait() {
        let gate = HostGate::new(Duration::from_secs(5));
        let start = Instant::now();
        let _a = gate.acquire("a.example").await;
        let _b = gate.acquire("b.example").await;
        assert!(start.elapsed() < Duration::from_millis(100));
    }
}
```

`fetcher/src/http/mod.rs` のテスト:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn config(proxy: Option<ProxyConfig>) -> HttpConfig {
        HttpConfig {
            user_agent: "Faraday v2.14.3".into(),
            connect_timeout: Duration::from_secs(2),
            total_timeout: Duration::from_millis(500),
            proxy,
            min_host_interval: Duration::from_millis(0),
        }
    }

    #[tokio::test]
    async fn follows_redirects_and_reports_final_url() {
        let server = MockServer::start().await;
        Mock::given(path("/old")).respond_with(ResponseTemplate::new(301).insert_header("Location", "/new")).mount(&server).await;
        Mock::given(path("/new")).and(header("User-Agent", "Faraday v2.14.3"))
            .respond_with(ResponseTemplate::new(200).set_body_string("ok")).mount(&server).await;
        let client = HttpClient::new(config(None)).unwrap();
        let res = client.get_feed(&format!("{}/old", server.uri()), false).await.unwrap();
        assert_eq!(res.body, b"ok");
        assert_eq!(res.final_url, format!("{}/new", server.uri()));
        assert!(res.redirected);
    }

    #[tokio::test]
    async fn too_many_redirects_is_an_error() {
        let server = MockServer::start().await;
        Mock::given(path("/loop")).respond_with(ResponseTemplate::new(302).insert_header("Location", "/loop")).mount(&server).await;
        let client = HttpClient::new(config(None)).unwrap();
        let err = client.get_feed(&format!("{}/loop", server.uri()), false).await.unwrap_err();
        assert!(matches!(err, FetchError::TooManyRedirects));
    }

    #[tokio::test]
    async fn slow_server_times_out() {
        let server = MockServer::start().await;
        Mock::given(path("/slow")).respond_with(ResponseTemplate::new(200).set_delay(Duration::from_secs(2))).mount(&server).await;
        let client = HttpClient::new(config(None)).unwrap();
        let err = client.get_feed(&format!("{}/slow", server.uri()), false).await.unwrap_err();
        assert!(matches!(err, FetchError::Timeout));
    }

    #[tokio::test]
    async fn retries_via_proxy_on_403_and_asks_to_register() {
        let origin = MockServer::start().await;
        Mock::given(path("/feed")).respond_with(ResponseTemplate::new(403)).mount(&origin).await;
        let proxy = MockServer::start().await;
        let target = format!("{}/feed", origin.uri());
        Mock::given(method("GET")).and(path("/")).and(header("X-Proxy-Secret", "s")).and(header("X-Target-URL", target.as_str()))
            .respond_with(ResponseTemplate::new(200).set_body_string("via proxy").insert_header("X-Original-URL", target.as_str()))
            .mount(&proxy).await;
        let client = HttpClient::new(config(Some(ProxyConfig { url: proxy.uri(), secret: "s".into() }))).unwrap();
        let res = client.get_feed(&target, false).await.unwrap();
        assert_eq!(res.body, b"via proxy");
        assert!(res.via_proxy);
        assert!(res.register_proxy_domain);
        assert!(!res.redirected);
    }

    #[tokio::test]
    async fn non_2xx_is_status_error_without_proxy() {
        let server = MockServer::start().await;
        Mock::given(path("/gone")).respond_with(ResponseTemplate::new(404)).mount(&server).await;
        let client = HttpClient::new(config(None)).unwrap();
        let err = client.get_feed(&format!("{}/gone", server.uri()), false).await.unwrap_err();
        assert!(matches!(err, FetchError::Status(404)));
        assert_eq!(err.kind(), "http_status");
    }
}
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `cd fetcher && cargo test --lib http`
Expected: コンパイルエラー

- [ ] **Step 3: 実装する**

`fetcher/src/http/host_gate.rs`:

```rust
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};
use tokio::time::Instant;

pub struct HostGate {
    hosts: Mutex<HashMap<String, Arc<AsyncMutex<Option<Instant>>>>>,
    min_interval: Duration,
}

pub struct HostPermit {
    guard: OwnedMutexGuard<Option<Instant>>,
}

impl Drop for HostPermit {
    fn drop(&mut self) {
        *self.guard = Some(Instant::now());
    }
}

impl HostGate {
    pub fn new(min_interval: Duration) -> Self {
        Self { hosts: Mutex::new(HashMap::new()), min_interval }
    }

    pub async fn acquire(&self, host: &str) -> HostPermit {
        let slot = {
            let mut hosts = self.hosts.lock().unwrap();
            hosts.entry(host.to_ascii_lowercase()).or_default().clone()
        };
        let guard = slot.lock_owned().await;
        if let Some(last) = *guard {
            let ready_at = last + self.min_interval;
            if ready_at > Instant::now() {
                tokio::time::sleep_until(ready_at).await;
            }
        }
        HostPermit { guard }
    }
}
```

`fetcher/src/http/mod.rs`:

```rust
pub mod host_gate;

use std::time::Duration;

use reqwest::header::{COOKIE, LOCATION, SET_COOKIE};
use reqwest::redirect::Policy;

use host_gate::HostGate;

const MAX_REDIRECTS: usize = 3;

#[derive(Debug, Clone)]
pub struct ProxyConfig {
    pub url: String,
    pub secret: String,
}

#[derive(Debug, Clone)]
pub struct HttpConfig {
    pub user_agent: String,
    pub connect_timeout: Duration,
    pub total_timeout: Duration,
    pub proxy: Option<ProxyConfig>,
    pub min_host_interval: Duration,
}

#[derive(Debug, Clone)]
pub struct FetchResponse {
    pub body: Vec<u8>,
    pub final_url: String,
    pub redirected: bool,
    pub via_proxy: bool,
    pub register_proxy_domain: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum FetchError {
    #[error("HTTP status {0}")]
    Status(u16),
    #[error("timeout")]
    Timeout,
    #[error("connect: {0}")]
    Connect(String),
    #[error("too many redirects")]
    TooManyRedirects,
    #[error("{0}")]
    Other(String),
}

impl FetchError {
    pub fn kind(&self) -> &'static str {
        match self {
            FetchError::Status(_) => "http_status",
            FetchError::Timeout => "timeout",
            FetchError::Connect(_) => "connect",
            FetchError::TooManyRedirects => "too_many_redirects",
            FetchError::Other(_) => "other",
        }
    }

    fn from_reqwest(e: reqwest::Error) -> Self {
        if e.is_timeout() {
            FetchError::Timeout
        } else if e.is_connect() {
            FetchError::Connect(e.to_string())
        } else {
            FetchError::Other(e.to_string())
        }
    }

    fn triggers_proxy(&self, is_feed: bool) -> bool {
        matches!(self, FetchError::Timeout | FetchError::Connect(_))
            || (is_feed && matches!(self, FetchError::Status(403)))
    }
}

pub struct HttpClient {
    client: reqwest::Client,
    config: HttpConfig,
    gate: HostGate,
}

impl HttpClient {
    pub fn new(config: HttpConfig) -> anyhow::Result<Self> {
        let client = reqwest::Client::builder()
            .user_agent(config.user_agent.clone())
            .connect_timeout(config.connect_timeout)
            .timeout(config.total_timeout)
            .redirect(Policy::none())
            .build()?;
        let gate = HostGate::new(config.min_host_interval);
        Ok(Self { client, config, gate })
    }

    pub async fn get_feed(&self, url: &str, use_proxy: bool) -> Result<FetchResponse, FetchError> {
        self.get(url, use_proxy, true).await
    }

    pub async fn get_page(&self, url: &str, use_proxy: bool) -> Result<FetchResponse, FetchError> {
        self.get(url, use_proxy, false).await
    }

    async fn get(&self, url: &str, use_proxy: bool, is_feed: bool) -> Result<FetchResponse, FetchError> {
        if use_proxy && self.config.proxy.is_some() {
            return self.via_proxy(url, false).await;
        }
        match self.direct(url).await {
            Ok(res) => Ok(res),
            Err(e) if e.triggers_proxy(is_feed) && self.config.proxy.is_some() => {
                tracing::info!(url, error = %e, "direct request failed, retrying via proxy");
                self.via_proxy(url, true).await
            }
            Err(e) => Err(e),
        }
    }

    async fn direct(&self, url: &str) -> Result<FetchResponse, FetchError> {
        let mut current = url::Url::parse(url).map_err(|e| FetchError::Other(e.to_string()))?;
        let mut cookies: Vec<String> = Vec::new();
        for hops in 0..=MAX_REDIRECTS {
            let host = current.host_str().unwrap_or_default().to_string();
            let _permit = self.gate.acquire(&host).await;
            let mut req = self.client.get(current.clone());
            if !cookies.is_empty() {
                req = req.header(COOKIE, cookies.join("; "));
            }
            let res = req.send().await.map_err(FetchError::from_reqwest)?;
            for value in res.headers().get_all(SET_COOKIE) {
                if let Some(pair) = value.to_str().ok().and_then(|v| v.split(';').next()) {
                    cookies.push(pair.trim().to_string());
                }
            }
            let status = res.status();
            if status.is_redirection() {
                let location = res
                    .headers()
                    .get(LOCATION)
                    .and_then(|v| v.to_str().ok())
                    .ok_or_else(|| FetchError::Other("redirect without location".into()))?;
                current = current.join(location).map_err(|e| FetchError::Other(e.to_string()))?;
                continue;
            }
            if !status.is_success() {
                return Err(FetchError::Status(status.as_u16()));
            }
            let final_url = current.to_string();
            let body = res.bytes().await.map_err(FetchError::from_reqwest)?.to_vec();
            return Ok(FetchResponse {
                body,
                // url::Url の正規化 (末尾の / や host の小文字化) だけで「リダイレクトした」にしない
                redirected: hops > 0 && final_url != url,
                final_url,
                via_proxy: false,
                register_proxy_domain: false,
            });
        }
        Err(FetchError::TooManyRedirects)
    }

    async fn via_proxy(&self, url: &str, is_retry: bool) -> Result<FetchResponse, FetchError> {
        let proxy = self.config.proxy.as_ref().expect("proxy is configured");
        let res = self
            .client
            .get(format!("{}/", proxy.url.trim_end_matches('/')))
            .header("X-Proxy-Secret", &proxy.secret)
            .header("X-Target-URL", url)
            .send()
            .await
            .map_err(FetchError::from_reqwest)?;
        let status = res.status();
        if !status.is_success() {
            return Err(FetchError::Status(status.as_u16()));
        }
        let final_url = res
            .headers()
            .get("X-Original-URL")
            .and_then(|v| v.to_str().ok())
            .unwrap_or(url)
            .to_string();
        let body = res.bytes().await.map_err(FetchError::from_reqwest)?.to_vec();
        Ok(FetchResponse {
            body,
            redirected: final_url != url,
            final_url,
            via_proxy: true,
            register_proxy_domain: is_retry,
        })
    }
}
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `cd fetcher && cargo test --lib http`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add fetcher/src
git commit -m "fetcherにリダイレクト・proxy再試行つきHTTPクライアントとホストごとの門番を追加"
```

---

### Task 8: OGP の取得

**Files:**
- Create: `fetcher/src/ogp.rs`
- Modify: `fetcher/src/lib.rs` (`pub mod ogp;`)

**Interfaces:**
- Consumes: `http::HttpClient::get_page`、`encoding::to_utf8_dropping_invalid`、`shape::channel::Ogp`
- Produces:
  - `fn extract_ogp(html: &str, page_url: &str) -> Ogp` (lib/open_graph.rb と同じ規則)
  - `async fn fetch_ogp(client: &HttpClient, url: &str, proxy_domains: &HashSet<String>) -> Option<Ogp>` (失敗したら None。Rails の `rescue nil` と同じ)

規則: `<title>` のテキスト。`og:image` / `og:description` は「どれかの属性の値がそれと等しい最初の `<meta>`」の `content`。`og:image` が `/` で始まるときだけ `page_url` を基準に絶対 URL にする。

- [ ] **Step 1: 失敗するテストを書く**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_like_open_graph_rb() {
        let html = r#"<html><head><title>Page</title>
            <meta name="og:description" content="desc">
            <meta property="og:image" content="/img/a.png">
            <meta property="og:image" content="/img/b.png">
        </head></html>"#;
        let ogp = extract_ogp(html, "https://example.com/post/1");
        assert_eq!(ogp.title.as_deref(), Some("Page"));
        assert_eq!(ogp.description.as_deref(), Some("desc"));
        assert_eq!(ogp.image.as_deref(), Some("https://example.com/img/a.png"));
    }

    #[test]
    fn keeps_non_slash_relative_image_as_is() {
        let html = r#"<meta property="og:image" content="img/a.png">"#;
        assert_eq!(extract_ogp(html, "https://example.com/post/1").image.as_deref(), Some("img/a.png"));
    }
}
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `cd fetcher && cargo test --lib ogp`
Expected: コンパイルエラー

- [ ] **Step 3: 実装する**

`fetcher/src/ogp.rs`:

```rust
use std::collections::HashSet;

use scraper::{Html, Selector};

use crate::encoding::to_utf8_dropping_invalid;
use crate::http::HttpClient;
use crate::shape::channel::Ogp;

fn meta_content(doc: &Html, key: &str) -> Option<String> {
    let selector = Selector::parse("meta").unwrap();
    doc.select(&selector)
        .find(|m| m.value().attrs().any(|(_, v)| v == key))
        .and_then(|m| m.value().attr("content").map(str::to_string))
}

pub fn extract_ogp(html: &str, page_url: &str) -> Ogp {
    let doc = Html::parse_document(html);
    let title_selector = Selector::parse("title").unwrap();
    let title: String = doc.select(&title_selector).flat_map(|t| t.text()).collect();
    let mut image = meta_content(&doc, "og:image");
    if let Some(img) = image.as_deref().filter(|i| i.starts_with('/')) {
        image = url::Url::parse(page_url).and_then(|b| b.join(img)).map(|u| u.to_string()).ok();
    }
    Ogp { title: Some(title), description: meta_content(&doc, "og:description"), image }
}

pub async fn fetch_ogp(client: &HttpClient, url: &str, proxy_domains: &HashSet<String>) -> Option<Ogp> {
    let host = url::Url::parse(url).ok()?.host_str()?.to_ascii_lowercase();
    let res = client.get_page(url, proxy_domains.contains(&host)).await.ok()?;
    Some(extract_ogp(&to_utf8_dropping_invalid(&res.body), url))
}
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `cd fetcher && cargo test --lib ogp`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add fetcher/src
git commit -m "fetcherにOGPの取得を追加"
```

---

### Task 9: dispatcher の土台 (認証・DB 接続・テスト環境)

**Files:**
- Create: `dispatcher/package.json`, `dispatcher/tsconfig.json`, `dispatcher/wrangler.toml`, `dispatcher/vitest.config.ts`
- Create: `dispatcher/src/index.ts`, `dispatcher/src/app.ts`, `dispatcher/src/auth.ts`, `dispatcher/src/db.ts`
- Create: `dispatcher/test/helpers.ts`, `dispatcher/test/auth.test.ts`
- Modify: `docker-compose.yml` (サービス `dispatcher` を追加)、`.gitignore`

**Interfaces:**
- Produces (`src/auth.ts`):
  - `sha256Hex(input: string): Promise<string>`
  - `constantTimeEqual(a: string, b: string): boolean`
  - `authenticate(authorization: string | undefined, workerTokensJson: string): Promise<string | null>` (一致したワーカー名。だめなら null)
- Produces (`src/db.ts`): `type Sql = postgres.Sql`、`openSql(connectionString: string): { sql: Sql; close: () => Promise<void> }` (`max: 5`、`fetch_types: false`、`connection: { TimeZone: "UTC" }`)
- Produces (`src/app.ts`):

```ts
export type Env = { HYPERDRIVE: { connectionString: string }; WORKER_TOKENS: string };
export type Deps = { openSql: (env: Env) => { sql: Sql; close: () => Promise<void> } };
export type Vars = { sql: Sql; workerName: string };
export function createApp(deps: Deps): Hono<{ Bindings: Env; Variables: Vars }>;
```

全ルートで認証 (失敗は 401 `{ "error": "unauthorized" }`) のあと、リクエストごとに DB 接続を開き、終わったら閉じる。

- [ ] **Step 1: パッケージとテスト環境を用意する**

`dispatcher/package.json`:

```json
{
  "name": "feeeed-dispatcher",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy",
    "test": "vitest run",
    "typecheck": "tsc --noEmit"
  }
}
```

依存は `docker compose run` の中で入れる (Step 2 のサービス定義のあと):

Run: `docker compose run --rm dispatcher npm install hono postgres && docker compose run --rm dispatcher npm install -D wrangler vitest typescript @cloudflare/workers-types @types/node`

`dispatcher/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "strict": true,
    "types": ["@cloudflare/workers-types", "@types/node"],
    "noEmit": true,
    "skipLibCheck": true
  },
  "include": ["src", "test", "vitest.config.ts"]
}
```

`dispatcher/vitest.config.ts`:

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    fileParallelism: false,
  },
});
```

`dispatcher/wrangler.toml`:

```toml
name = "feeeed-dispatcher"
main = "src/index.ts"
compatibility_date = "2026-09-01"
compatibility_flags = ["nodejs_compat"]

[observability]
enabled = true

# id は Task 12 で `wrangler hyperdrive create` した結果に置き換える
[[hyperdrive]]
binding = "HYPERDRIVE"
id = "00000000000000000000000000000000"
localConnectionString = "postgres://postgres:password@localhost:5432/feeeed_development"
```

- [ ] **Step 2: docker compose にテスト用サービスを足す**

`docker-compose.yml` の `services:` に追加 (`volumes:` にも `dispatcher_node_modules:` を足す):

```yaml
  dispatcher:
    image: node:24
    working_dir: /app/dispatcher
    volumes:
      - .:/app
      - dispatcher_node_modules:/app/dispatcher/node_modules
    environment:
      TEST_DATABASE_URL: postgres://postgres:password@database:5432/feeeed_test
    depends_on:
      - database
```

`.gitignore` に追加:

```
/dispatcher/node_modules
/dispatcher/.wrangler
```

テスト用 DB のスキーマを用意する:

Run: `docker compose run --rm -e RAILS_ENV=test web rails db:prepare`
Expected: `feeeed_test` にスキーマが入る

- [ ] **Step 3: 失敗するテストを書く**

`dispatcher/test/helpers.ts`:

```ts
import postgres from "postgres";
import { createApp, type Env } from "../src/app";
import { sha256Hex } from "../src/auth";

export const sql = postgres(process.env.TEST_DATABASE_URL!, {
  max: 2,
  fetch_types: false,
  connection: { TimeZone: "UTC" },
  onnotice: () => {},
});

export const TOKEN = "test-token";

export async function testEnv(): Promise<Env> {
  return {
    HYPERDRIVE: { connectionString: process.env.TEST_DATABASE_URL! },
    WORKER_TOKENS: JSON.stringify({ "test-machine": await sha256Hex(TOKEN) }),
  };
}

export const app = createApp({ openSql: () => ({ sql, close: async () => {} }) });

export async function request(path: string, init: RequestInit = {}, token: string | null = TOKEN) {
  const headers = new Headers(init.headers);
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (init.body) headers.set("Content-Type", "application/json");
  return app.request(path, { ...init, headers }, await testEnv());
}

export async function resetTables() {
  await sql`TRUNCATE channels, items, channel_stoppers, channel_fixed_schedules, proxy_required_domains RESTART IDENTITY CASCADE`;
}

export async function insertChannel(attrs: {
  feed_url: string;
  title?: string;
  site_url?: string | null;
  description?: string | null;
  image_url?: string | null;
  check_interval_hours?: number;
  last_items_checked_at?: Date | null;
}) {
  const [row] = await sql`
    INSERT INTO channels (feed_url, title, site_url, description, image_url, check_interval_hours, last_items_checked_at, created_at, updated_at)
    VALUES (${attrs.feed_url}, ${attrs.title ?? "t"}, ${attrs.site_url ?? null}, ${attrs.description ?? null}, ${attrs.image_url ?? null},
            ${attrs.check_interval_hours ?? 1}, ${attrs.last_items_checked_at ?? null}, now(), now())
    RETURNING id`;
  return Number(row.id);
}

export async function insertItem(channelId: number, guid: string, attrs: { title?: string; url?: string; published_at?: Date; data?: object } = {}) {
  await sql`
    INSERT INTO items (channel_id, guid, title, url, published_at, data, created_at, updated_at)
    VALUES (${channelId}, ${guid}, ${attrs.title ?? guid}, ${attrs.url ?? `https://example.com/${guid}`},
            ${attrs.published_at ?? new Date("2026-09-24T00:00:00Z")}, ${sql.json((attrs.data ?? {}) as any)}, now(), now())`;
}

export function hoursAgo(h: number) {
  return new Date(Date.now() - h * 3600 * 1000);
}
```

`dispatcher/test/auth.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { authenticate, constantTimeEqual, sha256Hex } from "../src/auth";
import { request } from "./helpers";

describe("authenticate", () => {
  it("トークンのハッシュが一致したワーカー名を返す", async () => {
    const tokens = JSON.stringify({ alpha: await sha256Hex("a"), beta: await sha256Hex("b") });
    expect(await authenticate("Bearer b", tokens)).toBe("beta");
    expect(await authenticate("Bearer c", tokens)).toBeNull();
    expect(await authenticate(undefined, tokens)).toBeNull();
    expect(await authenticate("Basic b", tokens)).toBeNull();
  });

  it("constantTimeEqual は長さが違えば false", () => {
    expect(constantTimeEqual("abc", "abc")).toBe(true);
    expect(constantTimeEqual("abc", "abd")).toBe(false);
    expect(constantTimeEqual("abc", "abcd")).toBe(false);
  });

  it("認証に失敗したら 401", async () => {
    const res = await request("/shadow/channels", {}, "wrong");
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "unauthorized" });
  });
});
```

- [ ] **Step 4: テストが失敗することを確認する**

Run: `docker compose run --rm dispatcher npm test`
Expected: FAIL (`../src/auth` が無い)

- [ ] **Step 5: 実装する**

`dispatcher/src/auth.ts`:

```ts
export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function authenticate(authorization: string | undefined, workerTokensJson: string): Promise<string | null> {
  const match = authorization?.match(/^Bearer (.+)$/);
  if (!match) return null;
  const hashed = await sha256Hex(match[1]);
  const tokens = JSON.parse(workerTokensJson) as Record<string, string>;
  let found: string | null = null;
  for (const [name, expected] of Object.entries(tokens)) {
    if (constantTimeEqual(hashed, expected)) found = name;
  }
  return found;
}
```

`dispatcher/src/db.ts`:

```ts
import postgres from "postgres";

export type Sql = postgres.Sql;

export function openSql(connectionString: string): { sql: Sql; close: () => Promise<void> } {
  const sql = postgres(connectionString, {
    max: 5,
    fetch_types: false,
    connection: { TimeZone: "UTC" },
  });
  return { sql, close: () => sql.end() };
}
```

`dispatcher/src/app.ts`:

```ts
import { Hono } from "hono";
import { authenticate } from "./auth";
import type { Sql } from "./db";

export type Env = { HYPERDRIVE: { connectionString: string }; WORKER_TOKENS: string };
export type Deps = { openSql: (env: Env) => { sql: Sql; close: () => Promise<void> } };
export type Vars = { sql: Sql; workerName: string };

export function createApp(deps: Deps) {
  const app = new Hono<{ Bindings: Env; Variables: Vars }>();

  app.use("*", async (c, next) => {
    const workerName = await authenticate(c.req.header("Authorization"), c.env.WORKER_TOKENS);
    if (!workerName) return c.json({ error: "unauthorized" }, 401);
    c.set("workerName", workerName);

    const { sql, close } = deps.openSql(c.env);
    c.set("sql", sql);
    try {
      await next();
    } finally {
      const closing = close();
      try {
        c.executionCtx.waitUntil(closing);
      } catch {
        await closing;
      }
    }
  });

  return app;
}
```

`dispatcher/src/index.ts`:

```ts
import { createApp, type Env } from "./app";
import { openSql } from "./db";

const app = createApp({ openSql: (env: Env) => openSql(env.HYPERDRIVE.connectionString) });

export default app;
```

- [ ] **Step 6: テストが通ることを確認する**

Run: `docker compose run --rm dispatcher npm test && docker compose run --rm dispatcher npm run typecheck`
Expected: PASS、型エラー無し

- [ ] **Step 7: コミット**

```bash
git add .gitignore docker-compose.yml dispatcher/package.json dispatcher/package-lock.json dispatcher/tsconfig.json dispatcher/wrangler.toml dispatcher/vitest.config.ts dispatcher/src dispatcher/test
git commit -m "dispatcher(Cloudflare Worker)の土台と認証を追加"
```

---

### Task 10: dispatcher の影モード用エンドポイント

**Files:**
- Create: `dispatcher/src/queries.ts`
- Modify: `dispatcher/src/app.ts` (ルートを追加)
- Create: `dispatcher/test/queries.test.ts`, `dispatcher/test/app.test.ts`

**Interfaces:**
- Produces (`src/queries.ts`):

```ts
export type DueChannel = {
  channel_id: number; feed_url: string; site_url: string | null; use_proxy: boolean;
  stored: { title: string; description: string | null; site_url: string | null; image_url: string | null };
};
export function selectDueChannels(sql: Sql, opts: { max: number; order: "priority" | "random" }): Promise<DueChannel[]>;
export function newFlags(sql: Sql, channelId: number, entries: { entry_id: string | null; url: string | null }[]): Promise<boolean[]>;
export type StoredItem = { guid: string; title: string; url: string; image_url: string | null; published_at: string;
  data: { summary: string | null; itunes_subtitle: string | null; enclosure_url: string | null; enclosure_type: string | null } };
export function storedItems(sql: Sql, channelId: number, guids: string[]): Promise<StoredItem[]>;
export function proxyRequiredDomains(sql: Sql): Promise<string[]>;
```

- Produces (HTTP):
  - `GET /shadow/channels?max=20&order=priority|random` → `{ "channels": DueChannel[], "proxy_required_domains": string[] }` (`max` は 1〜100、既定 20)
  - `POST /channels/:channel_id/new-guids` `{ "entries": [{ "entry_id", "url" }] }` (1000件まで) → `{ "new": boolean[] }`
  - `POST /shadow/channels/:channel_id/items` `{ "guids": string[] }` (1000件まで) → `{ "items": StoredItem[] }`
  - 入力が不正なら 400 `{ "error": "..." }`

選定の条件 (Rails の `not_stopped.needs_check_now.by_check_priority` と同じ):
- `channel_stoppers` に無い
- `last_items_checked_at` が NULL、または `last_items_checked_at < (now() AT TIME ZONE 'UTC') - (check_interval_hours 時間 - 10分)`、または `channel_fixed_schedules` に Asia/Tokyo での今の曜日 (日曜=0) と時が登録されている
- ホストごとに1件 (同じホストの中では `check_interval_hours, last_items_checked_at` の昇順で先頭。NULL は後ろ)
- `order=priority` なら `check_interval_hours, last_items_checked_at` の昇順 (NULL は後ろ)、`order=random` なら無作為
- `use_proxy` はホストが `proxy_required_domains.domain` と一致するか (大文字小文字を無視)

- [ ] **Step 1: 失敗するテストを書く**

`dispatcher/test/queries.test.ts`:

```ts
import { beforeEach, describe, expect, it } from "vitest";
import { newFlags, proxyRequiredDomains, selectDueChannels, storedItems } from "../src/queries";
import { hoursAgo, insertChannel, insertItem, resetTables, sql } from "./helpers";

function tokyoNow() {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: "Asia/Tokyo", weekday: "short", hour: "numeric", hourCycle: "h23" })
    .formatToParts(new Date());
  const weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(parts.find((p) => p.type === "weekday")!.value);
  const hour = Number(parts.find((p) => p.type === "hour")!.value);
  return { weekday, hour };
}

beforeEach(resetTables);

describe("selectDueChannels", () => {
  it("未チェック・間隔切れ・固定スケジュールのものを選び、停止中と間隔内は選ばない", async () => {
    const never = await insertChannel({ feed_url: "https://a.example/feed" });
    const overdue = await insertChannel({ feed_url: "https://b.example/feed", check_interval_hours: 3, last_items_checked_at: hoursAgo(3) });
    await insertChannel({ feed_url: "https://c.example/feed", check_interval_hours: 3, last_items_checked_at: hoursAgo(1) });
    const scheduled = await insertChannel({ feed_url: "https://d.example/feed", check_interval_hours: 24, last_items_checked_at: hoursAgo(1) });
    const { weekday, hour } = tokyoNow();
    await sql`INSERT INTO channel_fixed_schedules (channel_id, day_of_week, hour, created_at, updated_at) VALUES (${scheduled}, ${weekday}, ${hour}, now(), now())`;
    const stopped = await insertChannel({ feed_url: "https://e.example/feed" });
    await sql`INSERT INTO channel_stoppers (channel_id, reason, created_at, updated_at) VALUES (${stopped}, 'x', now(), now())`;

    const ids = (await selectDueChannels(sql, { max: 10, order: "priority" })).map((c) => c.channel_id).sort();
    expect(ids).toEqual([never, overdue, scheduled].sort());
  });

  it("間隔の10分前から対象になる", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed", check_interval_hours: 1, last_items_checked_at: hoursAgo(55 / 60) });
    expect((await selectDueChannels(sql, { max: 10, order: "priority" })).map((c) => c.channel_id)).toEqual([id]);
  });

  it("同じホストからは1件だけ、優先度順に選ぶ", async () => {
    const hourly = await insertChannel({ feed_url: "https://www.youtube.com/feeds/1", check_interval_hours: 1, last_items_checked_at: hoursAgo(5) });
    await insertChannel({ feed_url: "https://www.youtube.com/feeds/2", check_interval_hours: 24, last_items_checked_at: hoursAgo(48) });
    await insertChannel({ feed_url: "https://WWW.YOUTUBE.COM/feeds/3", check_interval_hours: 3, last_items_checked_at: hoursAgo(10) });
    const other = await insertChannel({ feed_url: "https://note.com/x/rss", check_interval_hours: 12, last_items_checked_at: hoursAgo(13) });

    const rows = await selectDueChannels(sql, { max: 10, order: "priority" });
    expect(rows.map((r) => r.channel_id)).toEqual([hourly, other]);
  });

  it("max で件数を絞り、use_proxy と保存済みの値を返す", async () => {
    await sql`INSERT INTO proxy_required_domains (domain, created_at, updated_at) VALUES ('blocked.example', now(), now())`;
    const id = await insertChannel({ feed_url: "https://blocked.example/feed", title: "T", site_url: "https://blocked.example/" });
    await insertChannel({ feed_url: "https://ok.example/feed" });
    const rows = await selectDueChannels(sql, { max: 1, order: "priority" });
    expect(rows).toHaveLength(1);
    const all = await selectDueChannels(sql, { max: 10, order: "priority" });
    const blocked = all.find((r) => r.channel_id === id)!;
    expect(blocked.use_proxy).toBe(true);
    expect(blocked.stored).toEqual({ title: "T", description: null, site_url: "https://blocked.example/", image_url: null });
    expect(await proxyRequiredDomains(sql)).toEqual(["blocked.example"]);
  });
});

describe("newFlags", () => {
  it("entry_id とも url とも一致しないものだけ true", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed" });
    await insertItem(id, "g1");
    await insertItem(id, "https://a.example/2");
    const flags = await newFlags(sql, id, [
      { entry_id: "g1", url: "https://a.example/1" },
      { entry_id: "g2", url: "https://a.example/2" },
      { entry_id: "g3", url: null },
      { entry_id: null, url: null },
    ]);
    expect(flags).toEqual([false, false, true, true]);
  });

  it("別のチャンネルの item は見ない", async () => {
    const a = await insertChannel({ feed_url: "https://a.example/feed" });
    const b = await insertChannel({ feed_url: "https://b.example/feed" });
    await insertItem(b, "g1");
    expect(await newFlags(sql, a, [{ entry_id: "g1", url: null }])).toEqual([true]);
  });
});

describe("storedItems", () => {
  it("guid で保存済みの item を返す", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed" });
    await insertItem(id, "g1", { title: "one", data: { summary: "s", enclosure_url: "https://a.example/1.mp3", other: "x" } });
    const items = await storedItems(sql, id, ["g1", "missing"]);
    expect(items).toEqual([
      {
        guid: "g1", title: "one", url: "https://example.com/g1", image_url: null,
        published_at: "2026-09-24T00:00:00Z",
        data: { summary: "s", itunes_subtitle: null, enclosure_url: "https://a.example/1.mp3", enclosure_type: null },
      },
    ]);
  });
});
```

`dispatcher/test/app.test.ts`:

```ts
import { beforeEach, describe, expect, it } from "vitest";
import { insertChannel, insertItem, request, resetTables } from "./helpers";

beforeEach(resetTables);

describe("routes", () => {
  it("GET /shadow/channels", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed" });
    const res = await request("/shadow/channels?max=5");
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.channels.map((c: any) => c.channel_id)).toEqual([id]);
    expect(body.proxy_required_domains).toEqual([]);
  });

  it("GET /shadow/channels は max が範囲外なら 400", async () => {
    expect((await request("/shadow/channels?max=0")).status).toBe(400);
    expect((await request("/shadow/channels?max=101")).status).toBe(400);
    expect((await request("/shadow/channels?order=oldest")).status).toBe(400);
  });

  it("POST /channels/:id/new-guids", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed" });
    await insertItem(id, "g1");
    const res = await request(`/channels/${id}/new-guids`, {
      method: "POST",
      body: JSON.stringify({ entries: [{ entry_id: "g1", url: null }, { entry_id: "g2", url: null }] }),
    });
    expect(await res.json()).toEqual({ new: [false, true] });
  });

  it("POST /channels/:id/new-guids は形が違えば 400", async () => {
    const res = await request("/channels/1/new-guids", { method: "POST", body: JSON.stringify({ guids: [] }) });
    expect(res.status).toBe(400);
  });

  it("POST /shadow/channels/:id/items", async () => {
    const id = await insertChannel({ feed_url: "https://a.example/feed" });
    await insertItem(id, "g1");
    const res = await request(`/shadow/channels/${id}/items`, { method: "POST", body: JSON.stringify({ guids: ["g1"] }) });
    const body = (await res.json()) as any;
    expect(body.items.map((i: any) => i.guid)).toEqual(["g1"]);
  });
});
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `docker compose run --rm dispatcher npm test`
Expected: FAIL (`../src/queries` が無い、ルートが 404)

- [ ] **Step 3: 実装する**

`dispatcher/src/queries.ts`:

```ts
import type { Sql } from "./db";

export type DueChannel = {
  channel_id: number;
  feed_url: string;
  site_url: string | null;
  use_proxy: boolean;
  stored: { title: string; description: string | null; site_url: string | null; image_url: string | null };
};

export type StoredItem = {
  guid: string;
  title: string;
  url: string;
  image_url: string | null;
  published_at: string;
  data: { summary: string | null; itunes_subtitle: string | null; enclosure_url: string | null; enclosure_type: string | null };
};

export async function selectDueChannels(sql: Sql, opts: { max: number; order: "priority" | "random" }): Promise<DueChannel[]> {
  const orderBy = opts.order === "random" ? sql`random()` : sql`check_interval_hours, last_items_checked_at`;
  const rows = await sql`
    WITH due AS (
      SELECT c.id, c.feed_url, c.site_url, c.title, c.description, c.image_url,
             c.check_interval_hours, c.last_items_checked_at,
             lower(substring(c.feed_url from '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:?#]+)')) AS host
      FROM channels c
      WHERE NOT EXISTS (SELECT 1 FROM channel_stoppers s WHERE s.channel_id = c.id)
        AND (
          c.last_items_checked_at IS NULL
          OR c.last_items_checked_at < (now() AT TIME ZONE 'UTC')
               - ((c.check_interval_hours || ' hours')::interval - interval '10 minutes')
          OR EXISTS (
            SELECT 1 FROM channel_fixed_schedules fs
            WHERE fs.channel_id = c.id
              AND fs.day_of_week = EXTRACT(DOW FROM now() AT TIME ZONE 'Asia/Tokyo')
              AND fs.hour = EXTRACT(HOUR FROM now() AT TIME ZONE 'Asia/Tokyo')
          )
        )
    ),
    per_host AS (
      SELECT DISTINCT ON (host) * FROM due
      ORDER BY host, check_interval_hours, last_items_checked_at
    )
    SELECT p.id, p.feed_url, p.site_url, p.title, p.description, p.image_url,
           EXISTS (SELECT 1 FROM proxy_required_domains d WHERE lower(d.domain) = p.host) AS use_proxy
    FROM per_host p
    ORDER BY ${orderBy}
    LIMIT ${opts.max}`;

  return rows.map((r) => ({
    channel_id: Number(r.id),
    feed_url: r.feed_url,
    site_url: r.site_url,
    use_proxy: r.use_proxy,
    stored: { title: r.title, description: r.description, site_url: r.site_url, image_url: r.image_url },
  }));
}

export async function newFlags(
  sql: Sql,
  channelId: number,
  entries: { entry_id: string | null; url: string | null }[],
): Promise<boolean[]> {
  if (entries.length === 0) return [];
  const rows = await sql`
    SELECT e.ord,
           NOT EXISTS (
             SELECT 1 FROM items i
             WHERE i.channel_id = ${channelId} AND (i.guid = e.entry_id OR i.guid = e.url)
           ) AS is_new
    FROM unnest(${entries.map((e) => e.entry_id)}::text[], ${entries.map((e) => e.url)}::text[])
         WITH ORDINALITY AS e(entry_id, url, ord)
    ORDER BY e.ord`;
  return rows.map((r) => r.is_new as boolean);
}

export async function storedItems(sql: Sql, channelId: number, guids: string[]): Promise<StoredItem[]> {
  if (guids.length === 0) return [];
  const rows = await sql`
    SELECT guid, title, url, image_url,
           to_char(published_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS published_at,
           data->>'summary' AS summary, data->>'itunes_subtitle' AS itunes_subtitle,
           data->>'enclosure_url' AS enclosure_url, data->>'enclosure_type' AS enclosure_type
    FROM items
    WHERE channel_id = ${channelId} AND guid = ANY(${guids}::text[])
    ORDER BY id`;
  return rows.map((r) => ({
    guid: r.guid,
    title: r.title,
    url: r.url,
    image_url: r.image_url,
    published_at: r.published_at,
    data: {
      summary: r.summary,
      itunes_subtitle: r.itunes_subtitle,
      enclosure_url: r.enclosure_url,
      enclosure_type: r.enclosure_type,
    },
  }));
}

export async function proxyRequiredDomains(sql: Sql): Promise<string[]> {
  const rows = await sql`SELECT lower(domain) AS domain FROM proxy_required_domains ORDER BY domain`;
  return rows.map((r) => r.domain as string);
}
```

`dispatcher/src/app.ts` の `return app;` の直前に追加 (import に `newFlags, proxyRequiredDomains, selectDueChannels, storedItems` を足す):

```ts
  const MAX_BATCH = 1000;

  const channelIdParam = (raw: string) => {
    const id = Number(raw);
    return Number.isSafeInteger(id) && id > 0 ? id : null;
  };

  app.get("/shadow/channels", async (c) => {
    const max = Number(c.req.query("max") ?? "20");
    const order = c.req.query("order") ?? "priority";
    if (!Number.isInteger(max) || max < 1 || max > 100) return c.json({ error: "max must be 1..100" }, 400);
    if (order !== "priority" && order !== "random") return c.json({ error: "order must be priority or random" }, 400);
    const sql = c.get("sql");
    const [channels, domains] = await Promise.all([
      selectDueChannels(sql, { max, order }),
      proxyRequiredDomains(sql),
    ]);
    return c.json({ channels, proxy_required_domains: domains });
  });

  app.post("/channels/:channel_id/new-guids", async (c) => {
    const channelId = channelIdParam(c.req.param("channel_id"));
    const body = await c.req.json().catch(() => null);
    const entries = body?.entries;
    const valid =
      Array.isArray(entries) &&
      entries.length <= MAX_BATCH &&
      entries.every(
        (e: any) =>
          e && (e.entry_id === null || typeof e.entry_id === "string") && (e.url === null || typeof e.url === "string"),
      );
    if (!channelId || !valid) return c.json({ error: "expected { entries: [{ entry_id, url }] }" }, 400);
    return c.json({ new: await newFlags(c.get("sql"), channelId, entries) });
  });

  app.post("/shadow/channels/:channel_id/items", async (c) => {
    const channelId = channelIdParam(c.req.param("channel_id"));
    const body = await c.req.json().catch(() => null);
    const guids = body?.guids;
    const valid = Array.isArray(guids) && guids.length <= MAX_BATCH && guids.every((g: any) => typeof g === "string");
    if (!channelId || !valid) return c.json({ error: "expected { guids: string[] }" }, 400);
    return c.json({ items: await storedItems(c.get("sql"), channelId, guids) });
  });
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `docker compose run --rm dispatcher npm test && docker compose run --rm dispatcher npm run typecheck`
Expected: PASS、型エラー無し

- [ ] **Step 5: コミット**

```bash
git add dispatcher/src dispatcher/test
git commit -m "dispatcherに影モード用の読み取り専用エンドポイントを追加"
```

---

### Task 11: fetcher の dispatcher クライアントと `shadow` コマンド

**Files:**
- Create: `fetcher/src/dispatcher_client.rs`, `fetcher/src/shadow.rs`
- Modify: `fetcher/src/lib.rs` (`pub mod dispatcher_client; pub mod shadow;`)、`fetcher/src/main.rs`

**Interfaces:**
- Consumes: Task 10 の HTTP API、`HttpClient`、`prepare`、`shape::*`
- Produces (`dispatcher_client.rs`):

```rust
pub struct DispatcherClient { /* base_url, token, reqwest::Client */ }
impl DispatcherClient {
    pub fn new(base_url: &str, token: &str) -> anyhow::Result<Self>;
    pub async fn shadow_channels(&self, max: u32, order: &str) -> anyhow::Result<ShadowBatch>;
    pub async fn new_flags(&self, channel_id: i64, entries: &[NewGuidQuery]) -> anyhow::Result<Vec<bool>>;
    pub async fn stored_items(&self, channel_id: i64, guids: &[String]) -> anyhow::Result<Vec<StoredItem>>;
}
#[derive(Deserialize)] pub struct ShadowBatch { pub channels: Vec<ShadowChannel>, pub proxy_required_domains: Vec<String> }
#[derive(Deserialize)] pub struct ShadowChannel { pub channel_id: i64, pub feed_url: String, pub site_url: Option<String>, pub use_proxy: bool, pub stored: StoredChannel }
#[derive(Deserialize)] pub struct StoredChannel { pub title: String, pub description: Option<String>, pub site_url: Option<String>, pub image_url: Option<String> }
#[derive(Serialize)] pub struct NewGuidQuery { pub entry_id: Option<String>, pub url: Option<String> }
#[derive(Deserialize)] pub struct StoredItem { pub guid: String, pub title: String, pub url: String, pub image_url: Option<String>, pub published_at: String, pub data: EntryData }
```

- Produces (`shadow.rs`):

```rust
#[derive(Serialize)] pub struct FieldDiff { pub field: &'static str, pub guid: Option<String>, pub rust: Option<String>, pub rails: Option<String> }
#[derive(Serialize)] pub struct ChannelReport {
    pub channel_id: i64, pub feed_url: String, pub status: &'static str,   // "ok" | "fetch_error" | "parse_error"
    pub error: Option<String>, pub format: Option<FeedFormat>, pub applied_filters: Vec<String>,
    pub entries_in_feed: usize, pub new_entries: usize, pub entries_compared: usize,
    pub skipped: Vec<Skipped>, pub diffs: Vec<FieldDiff>, pub elapsed_ms: u128,
}
pub fn compare_channel(stored: &StoredChannel, rust: Option<&ChannelMeta>, format: FeedFormat) -> Vec<FieldDiff>;
pub fn compare_entries(rust: &[ShapedEntry], stored: &[StoredItem]) -> Vec<FieldDiff>;
pub async fn run_shadow(opts: ShadowOptions) -> anyhow::Result<()>;
pub struct ShadowOptions { pub api_url: String, pub token: String, pub max: u32, pub order: String, pub concurrency: usize, pub out: PathBuf, pub http: HttpConfig }
```

比較の規則:
- チャンネル: `title` と `site_url` を比べる。`description` は YouTube 以外で比べる (YouTube は OGP 由来なので外す)。`image_url` は iTunes のときだけ比べる (他は OGP 由来)。Rust 側が None (未対応形式やバリデーション落ち) なら `field: "channel"` の差分を1件出す
- entry: 保存済みのもの (新規でないもの) だけ、guid で突き合わせて `title`、`url`、`published_at`、`data.summary`、`data.itunes_subtitle`、`data.enclosure_url`、`data.enclosure_type` を比べる。`image_url` は `image_pending_ogp` でないときだけ比べる
- 影モードでは OGP を一切取りに行かない (チャンネル情報も entry も)。負荷を増やさないため

- [ ] **Step 1: 失敗するテストを書く**

`fetcher/src/shadow.rs` のテスト:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::EntryData;

    fn entry(guid: &str, title: &str, pending: bool) -> ShapedEntry {
        ShapedEntry {
            guid: guid.into(),
            title: title.into(),
            url: format!("https://e/{guid}"),
            image_url: None,
            published_at: "2026-09-24T00:00:00Z".into(),
            data: EntryData::default(),
            image_pending_ogp: pending,
        }
    }

    fn stored(guid: &str, title: &str, image: Option<&str>) -> StoredItem {
        StoredItem {
            guid: guid.into(),
            title: title.into(),
            url: format!("https://e/{guid}"),
            image_url: image.map(str::to_string),
            published_at: "2026-09-24T00:00:00Z".into(),
            data: EntryData::default(),
        }
    }

    #[test]
    fn reports_field_diffs_and_skips_ogp_images() {
        let rust = vec![entry("g1", "same", true), entry("g2", "rust title", false)];
        let rails = vec![stored("g1", "same", Some("https://e/ogp.png")), stored("g2", "rails title", None)];
        let diffs = compare_entries(&rust, &rails);
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].field, "title");
        assert_eq!(diffs[0].guid.as_deref(), Some("g2"));
        assert_eq!(diffs[0].rails.as_deref(), Some("rails title"));
    }

    #[test]
    fn channel_description_is_ignored_for_youtube() {
        let stored = StoredChannel { title: "T".into(), description: Some("ogp".into()), site_url: Some("https://e/".into()), image_url: None };
        let meta = ChannelMeta { title: Some("T".into()), description: None, site_url: Some("https://e/".into()), image_url: None };
        assert!(compare_channel(&stored, Some(&meta), FeedFormat::AtomYoutube).is_empty());
        assert_eq!(compare_channel(&stored, Some(&meta), FeedFormat::Rss)[0].field, "description");
        assert_eq!(compare_channel(&stored, None, FeedFormat::Rss)[0].field, "channel");
    }
}
```

`fetcher/tests/shadow_e2e.rs` (dispatcher とフィードの両方を wiremock で立てて、`run_shadow` のレポートを確かめる):

```rust
use std::time::Duration;

use fetcher::http::HttpConfig;
use fetcher::shadow::{run_shadow, ShadowOptions};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

#[tokio::test]
async fn shadow_writes_one_report_line_per_channel() {
    let feeds = MockServer::start().await;
    let rss = r#"<rss version="2.0"><channel><title>T</title><link>https://e.example/</link><description>d</description>
        <item><title>A</title><link>https://e.example/a</link><guid isPermaLink="false">ga</guid><pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate></item>
        <item><title>B</title><link>https://e.example/b</link><guid isPermaLink="false">gb</guid><pubDate>Wed, 24 Sep 2026 01:00:00 +0000</pubDate></item>
    </channel></rss>"#;
    Mock::given(path("/ok.xml")).respond_with(ResponseTemplate::new(200).set_body_string(rss)).mount(&feeds).await;
    Mock::given(path("/gone.xml")).respond_with(ResponseTemplate::new(404)).mount(&feeds).await;

    let api = MockServer::start().await;
    let batch = serde_json::json!({
        "channels": [
            { "channel_id": 1, "feed_url": format!("{}/ok.xml", feeds.uri()), "site_url": "https://e.example/", "use_proxy": false,
              "stored": { "title": "T", "description": "d", "site_url": "https://e.example/", "image_url": null } },
            { "channel_id": 2, "feed_url": format!("{}/gone.xml", feeds.uri()), "site_url": null, "use_proxy": false,
              "stored": { "title": "G", "description": null, "site_url": null, "image_url": null } }
        ],
        "proxy_required_domains": []
    });
    Mock::given(method("GET")).and(path("/shadow/channels")).respond_with(ResponseTemplate::new(200).set_body_json(batch)).mount(&api).await;
    Mock::given(method("POST")).and(path("/channels/1/new-guids"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "new": [false, true] }))).mount(&api).await;
    Mock::given(method("POST")).and(path("/shadow/channels/1/items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "items": [
            { "guid": "ga", "title": "A (old)", "url": "https://e.example/a", "image_url": null, "published_at": "2026-09-24T00:00:00Z",
              "data": { "summary": null, "itunes_subtitle": null, "enclosure_url": null, "enclosure_type": null } }
        ] }))).mount(&api).await;

    let dir = std::env::temp_dir().join(format!("shadow-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = dir.join("report.jsonl");
    run_shadow(ShadowOptions {
        api_url: api.uri(),
        token: "t".into(),
        max: 10,
        order: "priority".into(),
        concurrency: 4,
        out: out.clone(),
        http: HttpConfig {
            user_agent: "Faraday v2.14.3".into(),
            connect_timeout: Duration::from_secs(2),
            total_timeout: Duration::from_secs(5),
            proxy: None,
            min_host_interval: Duration::from_millis(0),
        },
    })
    .await
    .unwrap();

    let lines: Vec<serde_json::Value> = std::fs::read_to_string(&out).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines.len(), 2);
    let ok = lines.iter().find(|l| l["channel_id"] == 1).unwrap();
    assert_eq!(ok["status"], "ok");
    assert_eq!(ok["entries_in_feed"], 2);
    assert_eq!(ok["new_entries"], 1);
    assert_eq!(ok["entries_compared"], 1);
    assert_eq!(ok["diffs"][0]["field"], "title");
    let gone = lines.iter().find(|l| l["channel_id"] == 2).unwrap();
    assert_eq!(gone["status"], "fetch_error");
    assert_eq!(gone["error"], "http_status: HTTP status 404");
}
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `cd fetcher && cargo test shadow`
Expected: コンパイルエラー

- [ ] **Step 3: dispatcher クライアントを実装する**

`fetcher/src/dispatcher_client.rs`:

```rust
use serde::{Deserialize, Serialize};

use crate::model::EntryData;

#[derive(Debug, Deserialize)]
pub struct ShadowBatch {
    pub channels: Vec<ShadowChannel>,
    pub proxy_required_domains: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ShadowChannel {
    pub channel_id: i64,
    pub feed_url: String,
    pub site_url: Option<String>,
    pub use_proxy: bool,
    pub stored: StoredChannel,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StoredChannel {
    pub title: String,
    pub description: Option<String>,
    pub site_url: Option<String>,
    pub image_url: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct NewGuidQuery {
    pub entry_id: Option<String>,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StoredItem {
    pub guid: String,
    pub title: String,
    pub url: String,
    pub image_url: Option<String>,
    pub published_at: String,
    pub data: EntryData,
}

pub struct DispatcherClient {
    base_url: String,
    token: String,
    client: reqwest::Client,
}

impl DispatcherClient {
    pub fn new(base_url: &str, token: &str) -> anyhow::Result<Self> {
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            token: token.to_string(),
            client: reqwest::Client::builder().timeout(std::time::Duration::from_secs(30)).build()?,
        })
    }

    pub async fn shadow_channels(&self, max: u32, order: &str) -> anyhow::Result<ShadowBatch> {
        Ok(self
            .client
            .get(format!("{}/shadow/channels", self.base_url))
            .query(&[("max", max.to_string()), ("order", order.to_string())])
            .bearer_auth(&self.token)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }

    pub async fn new_flags(&self, channel_id: i64, entries: &[NewGuidQuery]) -> anyhow::Result<Vec<bool>> {
        #[derive(Deserialize)]
        struct Res {
            new: Vec<bool>,
        }
        let res: Res = self
            .client
            .post(format!("{}/channels/{channel_id}/new-guids", self.base_url))
            .bearer_auth(&self.token)
            .json(&serde_json::json!({ "entries": entries }))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        Ok(res.new)
    }

    pub async fn stored_items(&self, channel_id: i64, guids: &[String]) -> anyhow::Result<Vec<StoredItem>> {
        #[derive(Deserialize)]
        struct Res {
            items: Vec<StoredItem>,
        }
        let res: Res = self
            .client
            .post(format!("{}/shadow/channels/{channel_id}/items", self.base_url))
            .bearer_auth(&self.token)
            .json(&serde_json::json!({ "guids": guids }))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        Ok(res.items)
    }
}
```

1チャンネルの entry が1000件を超えるときは、`new_flags` と `stored_items` を1000件ずつに分けて呼ぶ (dispatcher の上限)。分割は `shadow.rs` 側の `chunks(1000)` で行う。

- [ ] **Step 4: `shadow` を実装する**

`fetcher/src/shadow.rs`:

```rust
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use serde::Serialize;
use tokio::io::AsyncWriteExt;
use tokio::sync::{Mutex, Semaphore};

use crate::dispatcher_client::{DispatcherClient, NewGuidQuery, ShadowChannel, StoredChannel, StoredItem};
use crate::http::{HttpClient, HttpConfig};
use crate::model::{ChannelMeta, FeedFormat, ShapedEntry, Skipped};
use crate::shape;

const CHUNK: usize = 1000;

#[derive(Debug, Serialize)]
pub struct FieldDiff {
    pub field: &'static str,
    pub guid: Option<String>,
    pub rust: Option<String>,
    pub rails: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ChannelReport {
    pub channel_id: i64,
    pub feed_url: String,
    pub status: &'static str,
    pub error: Option<String>,
    pub format: Option<FeedFormat>,
    pub applied_filters: Vec<String>,
    pub entries_in_feed: usize,
    pub new_entries: usize,
    pub entries_compared: usize,
    pub skipped: Vec<Skipped>,
    pub diffs: Vec<FieldDiff>,
    pub elapsed_ms: u128,
}

pub struct ShadowOptions {
    pub api_url: String,
    pub token: String,
    pub max: u32,
    pub order: String,
    pub concurrency: usize,
    pub out: PathBuf,
    pub http: HttpConfig,
}

fn diff(field: &'static str, guid: Option<&str>, rust: Option<&str>, rails: Option<&str>) -> Option<FieldDiff> {
    (rust != rails).then(|| FieldDiff {
        field,
        guid: guid.map(str::to_string),
        rust: rust.map(str::to_string),
        rails: rails.map(str::to_string),
    })
}

pub fn compare_channel(stored: &StoredChannel, rust: Option<&ChannelMeta>, format: FeedFormat) -> Vec<FieldDiff> {
    let Some(meta) = rust else {
        return vec![FieldDiff { field: "channel", guid: None, rust: None, rails: Some(stored.title.clone()) }];
    };
    let mut out = Vec::new();
    out.extend(diff("title", None, meta.title.as_deref(), Some(&stored.title)));
    out.extend(diff("site_url", None, meta.site_url.as_deref(), stored.site_url.as_deref()));
    if format != FeedFormat::AtomYoutube {
        out.extend(diff("description", None, meta.description.as_deref(), stored.description.as_deref()));
    }
    if format == FeedFormat::ItunesRss {
        out.extend(diff("image_url", None, meta.image_url.as_deref(), stored.image_url.as_deref()));
    }
    out
}

pub fn compare_entries(rust: &[ShapedEntry], stored: &[StoredItem]) -> Vec<FieldDiff> {
    let by_guid: HashMap<&str, &ShapedEntry> = rust.iter().map(|e| (e.guid.as_str(), e)).collect();
    let mut out = Vec::new();
    for s in stored {
        let Some(r) = by_guid.get(s.guid.as_str()) else { continue };
        let g = Some(s.guid.as_str());
        out.extend(diff("title", g, Some(&r.title), Some(&s.title)));
        out.extend(diff("url", g, Some(&r.url), Some(&s.url)));
        out.extend(diff("published_at", g, Some(&r.published_at), Some(&s.published_at)));
        out.extend(diff("summary", g, r.data.summary.as_deref(), s.data.summary.as_deref()));
        out.extend(diff("itunes_subtitle", g, r.data.itunes_subtitle.as_deref(), s.data.itunes_subtitle.as_deref()));
        out.extend(diff("enclosure_url", g, r.data.enclosure_url.as_deref(), s.data.enclosure_url.as_deref()));
        out.extend(diff("enclosure_type", g, r.data.enclosure_type.as_deref(), s.data.enclosure_type.as_deref()));
        if !r.image_pending_ogp {
            out.extend(diff("image_url", g, r.image_url.as_deref(), s.image_url.as_deref()));
        }
    }
    out
}

fn empty_report(ch: &ShadowChannel, status: &'static str, error: String, started: Instant) -> ChannelReport {
    ChannelReport {
        channel_id: ch.channel_id,
        feed_url: ch.feed_url.clone(),
        status,
        error: Some(error),
        format: None,
        applied_filters: vec![],
        entries_in_feed: 0,
        new_entries: 0,
        entries_compared: 0,
        skipped: vec![],
        diffs: vec![],
        elapsed_ms: started.elapsed().as_millis(),
    }
}

async fn process(ch: ShadowChannel, http: &HttpClient, api: &DispatcherClient) -> anyhow::Result<ChannelReport> {
    let started = Instant::now();
    let res = match http.get_feed(&ch.feed_url, ch.use_proxy).await {
        Ok(r) => r,
        Err(e) => return Ok(empty_report(&ch, "fetch_error", format!("{}: {e}", e.kind()), started)),
    };
    let prepared = match crate::prepare(&res.body, &ch.feed_url) {
        Ok(p) => p,
        Err(e) => return Ok(empty_report(&ch, "parse_error", e.to_string(), started)),
    };
    let format = prepared.feed.format;
    let meta = shape::channel::channel_meta(&prepared.feed, &ch.feed_url, None);
    let site_url = meta.as_ref().and_then(|m| m.site_url.clone()).or(ch.site_url.clone());
    let (drafts, mut skipped) = shape::entry::draft_entries(&prepared.feed, site_url.as_deref());
    let entries_in_feed = prepared.feed.entries.len();

    let guids_in_draft_order: Vec<String> = drafts.iter().map(|d| d.guid.clone()).collect();
    let queries: Vec<NewGuidQuery> = drafts
        .iter()
        .map(|d| NewGuidQuery { entry_id: d.raw_entry_id.clone(), url: d.raw_url.clone() })
        .collect();
    let mut flags = Vec::with_capacity(queries.len());
    for chunk in queries.chunks(CHUNK) {
        flags.extend(api.new_flags(ch.channel_id, chunk).await?);
    }
    let new_entries = flags.iter().filter(|f| **f).count();

    // 影モードでは OGP を取らない。取るはずだったものは pending にして比較から外す
    let resolved = drafts
        .into_iter()
        .map(|d| {
            let pending = d.image == shape::entry::ImageCandidate::NeedsOgp;
            (d, None, pending)
        })
        .collect();
    let (entries, more_skipped) = shape::entry::finalize_entries(resolved);
    skipped.extend(more_skipped);

    // finalize でバリデーション落ちや guid の重複が除かれて位置がずれるので、guid で引く
    let is_new: HashMap<String, bool> = guids_in_draft_order.into_iter().zip(flags.iter().copied()).collect();
    let existing: Vec<String> = entries
        .iter()
        .filter(|e| is_new.get(&e.guid) == Some(&false))
        .map(|e| e.guid.clone())
        .collect();
    let mut stored = Vec::new();
    for chunk in existing.chunks(CHUNK) {
        stored.extend(api.stored_items(ch.channel_id, chunk).await?);
    }

    let mut diffs = compare_channel(&ch.stored, meta.as_ref(), format);
    diffs.extend(compare_entries(&entries, &stored));

    Ok(ChannelReport {
        channel_id: ch.channel_id,
        feed_url: ch.feed_url,
        status: "ok",
        error: None,
        format: Some(format),
        applied_filters: prepared.applied_filters,
        entries_in_feed,
        new_entries,
        entries_compared: stored.len(),
        skipped,
        diffs,
        elapsed_ms: started.elapsed().as_millis(),
    })
}

pub async fn run_shadow(opts: ShadowOptions) -> anyhow::Result<()> {
    let api = Arc::new(DispatcherClient::new(&opts.api_url, &opts.token)?);
    let http = Arc::new(HttpClient::new(opts.http.clone())?);
    let batch = api.shadow_channels(opts.max, &opts.order).await?;
    let _proxy_domains: HashSet<String> = batch.proxy_required_domains.into_iter().collect();

    let file = tokio::fs::File::create(&opts.out).await?;
    let writer = Arc::new(Mutex::new(file));
    let semaphore = Arc::new(Semaphore::new(opts.concurrency));
    let mut tasks = tokio::task::JoinSet::new();

    for ch in batch.channels {
        let (api, http, writer, semaphore) = (api.clone(), http.clone(), writer.clone(), semaphore.clone());
        tasks.spawn(async move {
            let _slot = semaphore.acquire_owned().await.unwrap();
            let channel_id = ch.channel_id;
            match process(ch, &http, &api).await {
                Ok(report) => {
                    let line = serde_json::to_string(&report).unwrap() + "\n";
                    writer.lock().await.write_all(line.as_bytes()).await.unwrap();
                }
                Err(e) => tracing::error!(channel_id, error = %e, "shadow failed"),
            }
        });
    }
    while tasks.join_next().await.is_some() {}
    writer.lock().await.flush().await?;
    Ok(())
}
```

`_proxy_domains` は影モードでは OGP を取らないので使わない (計画2で本番の取り込みに使う)。同じ guid の draft が複数あると `is_new` は後のもので上書きされるが、同じ guid なら DB での有無も同じなので問題ない。

- [ ] **Step 5: CLI をつなぐ**

`fetcher/src/main.rs`:

```rust
use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, Subcommand};
use fetcher::http::{HttpConfig, ProxyConfig};

#[derive(Parser)]
#[command(name = "fetcher")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// 本番の保存済みデータと突き合わせる (DB には書き込まない)
    Shadow {
        #[arg(long, env = "FETCHER_API_URL")]
        api_url: String,
        #[arg(long, env = "FETCHER_TOKEN", hide_env_values = true)]
        token: String,
        #[arg(long, default_value_t = 50)]
        max: u32,
        #[arg(long, default_value = "random")]
        order: String,
        #[arg(long, env = "FETCHER_CONCURRENCY", default_value_t = 8)]
        concurrency: usize,
        #[arg(long, default_value = "shadow-report.jsonl")]
        out: PathBuf,
        #[arg(long, env = "FETCHER_USER_AGENT", default_value = "Faraday v2.14.3")]
        user_agent: String,
        #[arg(long, env = "FEED_PROXY_URL")]
        proxy_url: Option<String>,
        #[arg(long, env = "FEED_PROXY_SECRET", hide_env_values = true)]
        proxy_secret: Option<String>,
    },
    /// DIR/*.xml を整形して DIR/*.golden.json と比べる (比較用コーパス向け)
    GoldenCheck { dir: PathBuf },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env()).init();
    match Cli::parse().command {
        Command::Shadow { api_url, token, max, order, concurrency, out, user_agent, proxy_url, proxy_secret } => {
            let proxy = proxy_url.zip(proxy_secret).map(|(url, secret)| ProxyConfig { url, secret });
            fetcher::shadow::run_shadow(fetcher::shadow::ShadowOptions {
                api_url,
                token,
                max,
                order,
                concurrency,
                out,
                http: HttpConfig {
                    user_agent,
                    connect_timeout: Duration::from_secs(10),
                    total_timeout: Duration::from_secs(30),
                    proxy,
                    min_host_interval: Duration::from_secs(1),
                },
            })
            .await
        }
        Command::GoldenCheck { dir } => fetcher::golden_check(&dir),
    }
}
```

`fetcher/src/lib.rs` に `golden_check` を追加する (Task 12 のコーパスで使う):

```rust
/// DIR/*.xml ごとに golden_output と DIR/<name>.golden.json を比べ、一致しないものを表示する。
pub fn golden_check(dir: &std::path::Path) -> anyhow::Result<()> {
    let mut failures = 0;
    let mut total = 0;
    let mut paths: Vec<_> = std::fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "xml"))
        .collect();
    paths.sort();
    for xml in paths {
        let name = xml.file_stem().unwrap().to_string_lossy().to_string();
        let golden_path = dir.join(format!("{name}.golden.json"));
        let Ok(golden) = std::fs::read_to_string(&golden_path) else { continue };
        total += 1;
        let url_path = dir.join(format!("{name}.url"));
        let feed_url = std::fs::read_to_string(&url_path)
            .map(|s| s.lines().next().unwrap_or_default().trim().to_string())
            .unwrap_or_else(|_| format!("https://example.com/{name}/feed.xml"));
        let expected: model::ShapedFeed = serde_json::from_str(&golden)?;
        match golden_output(&std::fs::read(&xml)?, &feed_url) {
            Ok(actual) if actual == expected => {}
            Ok(actual) => {
                failures += 1;
                println!("MISMATCH {name}");
                println!("  expected: {}", serde_json::to_string(&expected)?);
                println!("  actual:   {}", serde_json::to_string(&actual)?);
            }
            Err(e) => {
                failures += 1;
                println!("ERROR {name}: {e}");
            }
        }
    }
    println!("{} / {} matched", total - failures, total);
    Ok(())
}
```

- [ ] **Step 6: テストが通ることを確認する**

Run: `cd fetcher && cargo test`
Expected: 全件 PASS

- [ ] **Step 7: コミット**

```bash
git add fetcher/src fetcher/tests
git commit -m "fetcherにdispatcherクライアントと影モード(shadow)コマンドを追加"
```

---

### Task 12: 比較用コーパス・CI・ドキュメントと影モードの実行

**Files:**
- Create: `fetcher/scripts/collect_corpus.sh`
- Create: `fetcher/README.md`, `dispatcher/README.md`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: Task 1 の rake、Task 11 の `golden-check` / `shadow`

- [ ] **Step 1: コーパスを集めるスクリプトを書く**

`fetcher/scripts/collect_corpus.sh`:

```bash
#!/usr/bin/env bash
# 本番のフィードを比較用コーパスとして手元に保存する (gitignore 下。コミットしない)。
# 使い方: fetcher/scripts/collect_corpus.sh urls.txt
#   urls.txt は1行1フィードURL。
set -euo pipefail

list="$1"
dir="$(cd "$(dirname "$0")/.." && pwd)/testdata/corpus"
mkdir -p "$dir"

n=0
while IFS= read -r url; do
  [ -z "$url" ] && continue
  n=$((n + 1))
  name=$(printf "feed%03d" "$n")
  if curl -fsSL --max-time 30 -A "Faraday v2.14.3" -o "$dir/$name.xml" "$url"; then
    printf '%s\n' "$url" > "$dir/$name.url"
    echo "ok   $name $url"
  else
    rm -f "$dir/$name.xml"
    echo "fail $name $url"
  fi
  sleep 1
done < "$list"
```

Run: `chmod +x fetcher/scripts/collect_corpus.sh`

- [ ] **Step 2: コーパスを集めて golden と比べる**

本番から形式やホストがばらけるように約30件の feed_url を選ぶ。フィルタが適用されている10チャンネルは必ず含める (読み取り専用):

```bash
heroku pg:psql -a feedhub -c "
SET default_transaction_read_only = on;
(SELECT feed_url FROM channels WHERE applied_filters::text <> '[]')
UNION ALL
(SELECT DISTINCT ON (substring(feed_url from '://([^/:]+)')) feed_url FROM channels c
 WHERE NOT EXISTS (SELECT 1 FROM channel_stoppers s WHERE s.channel_id = c.id)
 ORDER BY substring(feed_url from '://([^/:]+)'), random() LIMIT 20);" -t -A > tmp/corpus-urls.txt
```

Run: `fetcher/scripts/collect_corpus.sh tmp/corpus-urls.txt && docker compose run --rm web rails "fetcher:golden[fetcher/testdata/corpus]" && (cd fetcher && cargo run -- golden-check testdata/corpus)`
Expected: 最後に `N / N matched`

一致しないものは、Task 6 Step 7 と同じ方針で Rust 側を直す。そのとき、原因になった形を最小の合成フィクスチャにして `fetcher/testdata/fixtures/` に足し、golden を作り直して、回帰テストとしてコミットする (本番フィードそのものはコミットしない)。

- [ ] **Step 3: CI に fetcher と dispatcher のテストを足す**

`.github/workflows/ci.yml` の `test` ジョブの `Run tests` の後ろに追加する (Rails のテスト用 DB をそのまま使う):

```yaml
      - name: Set up Node
        uses: actions/setup-node@v4
        with:
          node-version: 24
          cache: npm
          cache-dependency-path: dispatcher/package-lock.json

      - name: Run dispatcher tests
        working-directory: dispatcher
        env:
          TEST_DATABASE_URL: postgres://postgres:postgres@localhost:5432/feeeed_test
        run: |
          npm ci
          npm run typecheck
          npm test
```

`jobs:` にジョブを追加する:

```yaml
  fetcher:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: fetcher
    steps:
      - uses: actions/checkout@v7
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: clippy, rustfmt
      - uses: Swatinem/rust-cache@v2
        with:
          workspaces: fetcher
      - run: cargo fmt --check
      - run: cargo clippy --all-targets -- -D warnings
      - run: cargo test
```

Run: `cd fetcher && cargo fmt && cargo clippy --all-targets -- -D warnings && cargo test`
Expected: 警告無し、全件 PASS

- [ ] **Step 4: README を書く**

`fetcher/README.md` に書くこと (見出しと中身):
- 何をするものか (spec へのリンク)
- ビルド: `cargo build --release` → `target/release/fetcher`
- 環境変数: `FETCHER_API_URL`、`FETCHER_TOKEN`、`FETCHER_CONCURRENCY`、`FETCHER_USER_AGENT`、`FEED_PROXY_URL`、`FEED_PROXY_SECRET`
- `fetcher shadow --max 50 --order random --out report.jsonl` の使い方と、レポートの読み方 (`jq -s 'map(.diffs[]) | group_by(.field) | map({field: .[0].field, count: length})' report.jsonl` で項目ごとの差分の数、`jq -s 'map(select(.status != "ok")) | group_by(.error | split(":")[0]) | map({kind: .[0].error, count: length})' report.jsonl` でエラーの種類)
- 比較用コーパスの手順 (Task 12 Step 2 のコマンド)
- golden の作り直し: `docker compose run --rm web rails "fetcher:golden[fetcher/testdata/fixtures]"`

`dispatcher/README.md` に書くこと:
- 何をするものか、エンドポイント一覧 (Task 10 の3つ)
- テスト: `docker compose run --rm -e RAILS_ENV=test web rails db:prepare` のあと `docker compose run --rm dispatcher npm test`
- ワーカーのトークンの発行: `openssl rand -hex 32` でトークンを作り、`printf %s "$TOKEN" | shasum -a 256` のハッシュを `WORKER_TOKENS` (JSON) に入れて `npx wrangler secret put WORKER_TOKENS`
- Hyperdrive の作成: `npx wrangler hyperdrive create feeeed-db --connection-string="$(heroku config:get DATABASE_URL -a feedhub)"` で出た id を `wrangler.toml` に書く
- Heroku Postgres の認証情報が変わったとき: `npx wrangler hyperdrive update <id> --connection-string="$(heroku config:get DATABASE_URL -a feedhub)"`
- デプロイ: `npx wrangler deploy`

- [ ] **Step 5: コミット**

```bash
git add fetcher/scripts/collect_corpus.sh fetcher/README.md dispatcher/README.md .github/workflows/ci.yml fetcher/testdata/fixtures
git commit -m "fetcher/dispatcherのCI・README・比較用コーパスの手順を追加"
```

- [ ] **Step 6: 本番で影モードを回す (ユーザーの確認を取ってから)**

ここから先は外部サービス (Cloudflare、本番 DB への読み取り接続) を触るので、各コマンドの前にユーザーに確認する。

1. Hyperdrive を作って `wrangler.toml` の id を置き換える (README の手順)。置き換えた `wrangler.toml` をコミットする
2. トークンを1つ発行して `WORKER_TOKENS` を登録する (README の手順)
3. `docker compose run --rm dispatcher npx wrangler deploy`
4. 手元で `fetcher shadow --max 50 --order random --out tmp/shadow-1.jsonl` を実行する
5. README の `jq` で集計し、結果 (エラーの種類と件数、項目ごとの差分の件数、代表的な差分の例) をユーザーに報告する

この報告をもとに、計画2 (本番の取り込みへの切り替え) を書く。
