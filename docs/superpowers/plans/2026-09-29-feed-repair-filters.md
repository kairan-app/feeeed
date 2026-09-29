# 壊れたフィードを直すフィルタ (計画2a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 壊れたフィード (未定義のエンティティ、素の `&`、制御文字、日本語の日時、改行入りの `<link>`、空の `<guid/>`、`/` で始まらない相対 URL) を、Rails と Rust の両方で「直してから読む」ようにし、途中で entry を黙って捨てないようにする。

**Architecture:** パース前フィルタを文字列のまま走査する方式で足す (CDATA・コメント・処理命令・DOCTYPE の中は書き換えない)。HTML のエンティティ表は JSON 1 ファイルを Ruby と Rust で共有する。Rails 側を先に作って本番にデプロイし、その Rails で golden を作り直してから Rust を一致させる。

**Tech Stack:** Rails 8.1 / Minitest + mocha / Feedjira、Rust (regex, serde_json, quick-xml)

**Spec:** `docs/superpowers/specs/2026-09-29-feed-repair-filters-design.md`

## Global Constraints

- guid の決め方 (`entry_id` → `url`、書かれたままの値) は変えない。例外は RSS の空の guid (`:no_buffer`) を entry_id 無しとして扱うことだけ
- パース前フィルタの順番: `InvalidXmlCharRemover` → `HtmlEntityFixer` → `BareAmpersandEscaper` → `LocalizedDateFixer` → `AtomNamespaceFixer`
- フィルタ名は Ruby のクラス名 (demodulize 後) と Rust の `name()` で同じ文字列にする
- 2〜4 のフィルタは CDATA・コメント・処理命令 (`<?...?>`)・DOCTYPE の外だけを書き換える。1 は生の制御文字を文書全体から取り除き、文字参照は外側だけで取り除く
- フィルタが例外を出したら、そのフィルタを飛ばして元の文字列のまま次に進み、Sentry に送る
- エンティティ表は `app/services/feed_filters/data/html_entities.json` の1ファイルだけ。Rust は `include_str!` で埋め込む
- Rails のコマンドは `docker compose run --rm web ...` で実行する。ファイルを編集したら `docker compose run --rm web bundle exec rubocop -c .rubocop.yml` を通す
- Rust は `cd fetcher && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` を通す
- 本番のフィード本文やレポートはコミットしない (`tmp/`、`fetcher/testdata/corpus/` は gitignore 下)
- 他プロジェクトの固有名詞をコード・コメント・コミットメッセージに入れない

## Review Focus

- 巨大なフィード (数十MB) でも、フィルタが遅くならないこと (正規表現が破局的なバックトラックをしない。`.*?` は CDATA などの区切りの中だけで使う) → Task 1 の性能テスト
- 閉じていない CDATA (`<![CDATA[` だけあって `]]>` が無い) では、そこから後ろを書き換え対象として扱ってよい (libxml2 はどのみち止まる) が、例外を出さないこと → Task 1 のテスト
- DOCTYPE で独自のエンティティを宣言しているフィード (`<!ENTITY`) では、`HtmlEntityFixer` が宣言済みの名前を `&amp;name;` に壊さないこと → Task 3 で「`<!ENTITY` を含む文書には適用しない」テスト
- `&#X41;` (大文字の X) は XML の文字参照ではないので、`BareAmpersandEscaper` が `&amp;#X41;` にすること → Task 4 のテスト
- 英語の日時や、`月` を含むが日時でない本文 (`<title>9月の予定</title>`) を `LocalizedDateFixer` が書き換えないこと → Task 5 のテスト

---

## Part 1: Rails

作業ブランチは `design/feed-repair-filters` (spec と、この plan をコミット済み)。

### Task 1: エンティティ表と、書き換えてよい部分の切り出し (Ruby)

**Files:**
- Create: `app/services/feed_filters/data/html_entities.json`
- Create: `app/services/feed_filters/html_entities.rb`
- Create: `app/services/feed_filters/pre_parse/xml_segments.rb`
- Test: `test/services/feed_filters/pre_parse/xml_segments_test.rb`
- Test: `test/services/feed_filters/html_entities_test.rb`

**Interfaces:**
- Produces: `FeedFilters::HtmlEntities::TABLE` (`Hash<String, String>`、キーは `;` と `&` を除いた名前、値は展開後の文字列)
- Produces: `FeedFilters::PreParse::XmlSegments.map_unprotected(xml) { |text| String } -> String`

- [ ] **Step 1: エンティティ表を作る**

```bash
mkdir -p app/services/feed_filters/data
curl -fsSL https://html.spec.whatwg.org/entities.json \
  | jq -S 'to_entries
           | map(select(.key | endswith(";")))
           | map({key: (.key | ltrimstr("&") | rtrimstr(";")), value: .value.characters})
           | from_entries' \
  > app/services/feed_filters/data/html_entities.json
jq 'length' app/services/feed_filters/data/html_entities.json
jq -r '.nbsp, .copy, .amp' app/services/feed_filters/data/html_entities.json | od -c | head -3
```

Expected: 件数が 2000 以上。`nbsp` が U+00A0 (`302 240`)、`copy` が `©`、`amp` が `&`

- [ ] **Step 2: 失敗するテストを書く**

`test/services/feed_filters/html_entities_test.rb`:

```ruby
require "test_helper"

class FeedFilters::HtmlEntitiesTest < ActiveSupport::TestCase
  test "WHATWG の名前付き文字参照を ; と & を除いた名前で引ける" do
    assert_equal " ", FeedFilters::HtmlEntities::TABLE["nbsp"]
    assert_equal "©", FeedFilters::HtmlEntities::TABLE["copy"]
    assert_equal "&", FeedFilters::HtmlEntities::TABLE["amp"]
    assert_nil FeedFilters::HtmlEntities::TABLE["nbsp;"]
    assert_operator FeedFilters::HtmlEntities::TABLE.size, :>, 2000
  end
end
```

`test/services/feed_filters/pre_parse/xml_segments_test.rb`:

```ruby
require "test_helper"

class FeedFilters::PreParse::XmlSegmentsTest < ActiveSupport::TestCase
  def upcase_outside(xml)
    FeedFilters::PreParse::XmlSegments.map_unprotected(xml, &:upcase)
  end

  test "CDATA・コメント・処理命令・DOCTYPE の中は渡さない" do
    xml = %(<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x "y">]><a>b<![CDATA[c & d]]>e<!-- f --></a>)
    assert_equal %(<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x "y">]><A>B<![CDATA[c & d]]>E<!-- f --></A>),
                 upcase_outside(xml)
  end

  test "区切りが無ければ全体を渡す" do
    assert_equal "<A>B</A>", upcase_outside("<a>b</a>")
  end

  test "閉じていない CDATA は、そこから後ろも書き換え対象として扱う" do
    assert_equal "<A><![CDATA[B", upcase_outside("<a><![CDATA[b")
  end

  test "巨大な文書でも速く終わる" do
    xml = "<a>" + ("<b>x &amp; y</b><![CDATA[z]]>" * 200_000) + "</a>"
    elapsed = Benchmark.realtime { FeedFilters::PreParse::XmlSegments.map_unprotected(xml) { _1 } }
    assert_operator elapsed, :<, 5
  end
end
```

- [ ] **Step 3: テストが失敗することを確かめる**

Run: `docker compose run --rm web rails test test/services/feed_filters/html_entities_test.rb test/services/feed_filters/pre_parse/xml_segments_test.rb`
Expected: FAIL (`uninitialized constant FeedFilters::HtmlEntities` / `XmlSegments`)

- [ ] **Step 4: 実装する**

`app/services/feed_filters/html_entities.rb`:

```ruby
module FeedFilters
  # WHATWG の名前付き文字参照 (HTML のエンティティ) の表。Rust の fetcher も同じ JSON を読む。
  module HtmlEntities
    TABLE = JSON.parse(File.read(File.expand_path("data/html_entities.json", __dir__))).freeze
  end
end
```

`app/services/feed_filters/pre_parse/xml_segments.rb`:

```ruby
module FeedFilters
  module PreParse
    # XML 文字列を「書き換えてよい部分」と「CDATA・コメント・処理命令・DOCTYPE」に分け、
    # 書き換えてよい部分だけをブロックで変換してつなぎ直す。
    # Rust 版 (fetcher/src/filters/segments.rs) と同じ正規表現を使う。
    module XmlSegments
      PROTECTED = /<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|<!DOCTYPE[^\[>]*(?:\[.*?\])?[ \t\r\n]*>/m

      def self.map_unprotected(xml)
        out = +""
        pos = 0
        xml.scan(PROTECTED) do
          match = Regexp.last_match
          out << yield(xml[pos...match.begin(0)]) << match[0]
          pos = match.end(0)
        end
        out << yield(xml[pos..])
      end
    end
  end
end
```

- [ ] **Step 5: テストが通ることを確かめる**

Run: 同上
Expected: PASS

- [ ] **Step 6: rubocop を通してコミット**

```bash
docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/services/feed_filters test/services/feed_filters
git add app/services/feed_filters/data/html_entities.json app/services/feed_filters/html_entities.rb \
  app/services/feed_filters/pre_parse/xml_segments.rb \
  test/services/feed_filters/html_entities_test.rb test/services/feed_filters/pre_parse/xml_segments_test.rb
git commit -m "フィード修正フィルタ用にHTMLのエンティティ表とXMLの書き換え範囲の切り出しを追加"
```

### Task 2: InvalidXmlCharRemover (Ruby)

**Files:**
- Create: `app/services/feed_filters/pre_parse/invalid_xml_char_remover.rb`
- Test: `test/services/feed_filters/pre_parse/invalid_xml_char_remover_test.rb`

**Interfaces:**
- Consumes: `XmlSegments.map_unprotected`
- Produces: `FeedFilters::PreParse::InvalidXmlCharRemover` (`Base` を継承。`details` は `{ removed_chars: Integer, removed_refs: Integer }`)

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "test_helper"

class FeedFilters::PreParse::InvalidXmlCharRemoverTest < ActiveSupport::TestCase
  def run_filter(xml)
    filter = FeedFilters::PreParse::InvalidXmlCharRemover.new
    out = filter.applicable?(xml) ? filter.apply(xml) : xml
    [ out, filter ]
  end

  test "XML で使えない生の文字を CDATA の中も含めて取り除く" do
    out, filter = run_filter("<a>x\u0008y<![CDATA[p\u0001q]]>￾</a>")
    assert_equal "<a>xy<![CDATA[pq]]></a>", out
    assert filter.applied
    assert_equal({ removed_chars: 3, removed_refs: 0 }, filter.details)
  end

  test "XML で使えない文字を指す文字参照を取り除く (CDATA の外だけ)" do
    out, filter = run_filter(%(<a b="&#x1F;">&#8;&#xD800;&#1114112;<![CDATA[&#8;]]></a>))
    assert_equal %(<a b=""><![CDATA[&#8;]]></a>), out
    assert_equal({ removed_chars: 0, removed_refs: 4 }, filter.details)
  end

  test "タブ・LF・CR と正しい文字参照はそのまま" do
    xml = "<a>\t\n\r&#9;&#xA;&#x3042;&#65;</a>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end
end
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose run --rm web rails test test/services/feed_filters/pre_parse/invalid_xml_char_remover_test.rb`
Expected: FAIL (`uninitialized constant`)

- [ ] **Step 3: 実装する**

```ruby
module FeedFilters
  module PreParse
    # XML 1.0 で使えない文字 (タブ・LF・CR 以外の制御文字、U+FFFE/U+FFFF) を取り除く。
    # libxml2 はこれらに出会うとそこで読むのをやめ、以降の entry が捨てられてしまう。
    class InvalidXmlCharRemover < Base
      INVALID_CHAR = /[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/
      CHAR_REF = /&#(?:x([0-9A-Fa-f]+)|([0-9]+));/

      def self.xml_char?(code)
        code == 0x9 || code == 0xA || code == 0xD ||
          (0x20..0xD7FF).cover?(code) || (0xE000..0xFFFD).cover?(code) || (0x10000..0x10FFFF).cover?(code)
      end

      def applicable?(xml_content, metadata = {})
        xml_content.match?(INVALID_CHAR) || xml_content.include?("&#")
      end

      def apply(xml_content, metadata = {})
        removed_chars = 0
        removed_refs = 0

        without_chars = xml_content.gsub(INVALID_CHAR) do
          removed_chars += 1
          ""
        end
        fixed = XmlSegments.map_unprotected(without_chars) do |text|
          text.gsub(CHAR_REF) do |ref|
            code = $1 ? $1.to_i(16) : $2.to_i
            next ref if self.class.xml_char?(code)

            removed_refs += 1
            ""
          end
        end

        mark_as_applied!(removed_chars: removed_chars, removed_refs: removed_refs) if removed_chars + removed_refs > 0
        fixed
      end
    end
  end
end
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: 同上
Expected: PASS

- [ ] **Step 5: rubocop を通してコミット**

```bash
docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/services/feed_filters test/services/feed_filters
git add app/services/feed_filters/pre_parse/invalid_xml_char_remover.rb test/services/feed_filters/pre_parse/invalid_xml_char_remover_test.rb
git commit -m "XMLで使えない文字を取り除くInvalidXmlCharRemoverを追加"
```

### Task 3: HtmlEntityFixer を文書全体に広げる (Ruby)

**Files:**
- Modify: `app/services/feed_filters/pre_parse/html_entity_fixer.rb` (全体を置き換え)
- Modify: `test/services/feed_filters/pre_parse/html_entity_fixer_test.rb` (全体を置き換え)

**Interfaces:**
- Consumes: `XmlSegments.map_unprotected`、`HtmlEntities::TABLE`
- Produces: `details` は `{ replaced: Integer, unknown: Integer }`

- [ ] **Step 1: テストを新しい振る舞いで書き直す (失敗するテスト)**

```ruby
require "test_helper"

class FeedFilters::PreParse::HtmlEntityFixerTest < ActiveSupport::TestCase
  def run_filter(xml)
    filter = FeedFilters::PreParse::HtmlEntityFixer.new
    out = filter.applicable?(xml) ? filter.apply(xml) : xml
    [ out, filter ]
  end

  test "HTML のエンティティを本文と属性の両方で数値の文字参照にする" do
    out, filter = run_filter(%(<a href="/?x=&nbsp;">&copy; 2026&hellip;</a>))
    assert_equal %(<a href="/?x=&#xA0;">&#xA9; 2026&#x2026;</a>), out
    assert_equal({ replaced: 3, unknown: 0 }, filter.details)
  end

  test "2文字に展開されるエンティティは2つの文字参照にする" do
    out, = run_filter("<a>&NotEqualTilde;</a>")
    assert_equal "<a>&#x2242;&#x338;</a>", out
  end

  test "表に無い名前は &amp;name; にして文字として残す" do
    out, filter = run_filter("<a>&foo; &bar;</a>")
    assert_equal "<a>&amp;foo; &amp;bar;</a>", out
    assert_equal({ replaced: 0, unknown: 2 }, filter.details)
  end

  test "XML の定義済みエンティティと数値の文字参照はそのまま" do
    xml = "<a>&amp;&lt;&gt;&quot;&apos;&#65;&#x41;</a>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "CDATA とコメントの中は書き換えない" do
    xml = "<a><![CDATA[&nbsp;]]><!-- &copy; --></a>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "独自のエンティティを宣言している文書には適用しない" do
    xml = %(<!DOCTYPE rss [<!ENTITY myent "x">]><a>&myent;&nbsp;</a>)
    assert_not FeedFilters::PreParse::HtmlEntityFixer.new.applicable?(xml)
  end

  test "これまでの対象だった channel の copyright も直る" do
    xml = "<rss><channel><copyright>&copy; 2025</copyright><title>t</title></channel></rss>"
    out, = run_filter(xml)
    assert_equal "<rss><channel><copyright>&#xA9; 2025</copyright><title>t</title></channel></rss>", out
  end
end
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose run --rm web rails test test/services/feed_filters/pre_parse/html_entity_fixer_test.rb`
Expected: FAIL (今の実装は copyright と generator しか見ないため)

- [ ] **Step 3: 実装を置き換える**

```ruby
module FeedFilters
  module PreParse
    # 名前付きのエンティティ (&nbsp; など) を直すフィルタ。
    # XML で定義されているのは amp/lt/gt/quot/apos だけなので、それ以外の名前があると
    # libxml2 はそこで読むのをやめ、以降の entry が捨てられてしまう。
    # HTML の表にある名前は数値の文字参照に置き換え、表に無い名前は &amp;name; にして文字として残す。
    # 以前は channel の copyright と generator だけを対象にしていた。
    class HtmlEntityFixer < Base
      NAMED_REF = /&([A-Za-z][A-Za-z0-9]*);/
      PREDEFINED = %w[amp lt gt quot apos].freeze

      def applicable?(xml_content, metadata = {})
        # 独自のエンティティを宣言している文書は、宣言済みの名前を壊さないよう対象外にする
        xml_content.match?(NAMED_REF) && !xml_content.include?("<!ENTITY")
      end

      def apply(xml_content, metadata = {})
        replaced = 0
        unknown = 0

        fixed = XmlSegments.map_unprotected(xml_content) do |text|
          text.gsub(NAMED_REF) do |ref|
            name = $1
            chars = HtmlEntities::TABLE[name]
            if PREDEFINED.include?(name)
              ref
            elsif chars
              replaced += 1
              chars.codepoints.map { format("&#x%X;", _1) }.join
            else
              unknown += 1
              "&amp;#{name};"
            end
          end
        end

        mark_as_applied!(replaced: replaced, unknown: unknown) if replaced + unknown > 0
        fixed
      end
    end
  end
end
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: 同上
Expected: PASS

- [ ] **Step 5: rubocop を通してコミット**

```bash
docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/services/feed_filters test/services/feed_filters
git add app/services/feed_filters/pre_parse/html_entity_fixer.rb test/services/feed_filters/pre_parse/html_entity_fixer_test.rb
git commit -m "HtmlEntityFixerの対象を文書全体に広げ、エンティティを数値の文字参照に置き換える"
```

### Task 4: BareAmpersandEscaper (Ruby)

**Files:**
- Create: `app/services/feed_filters/pre_parse/bare_ampersand_escaper.rb`
- Test: `test/services/feed_filters/pre_parse/bare_ampersand_escaper_test.rb`

**Interfaces:**
- Consumes: `XmlSegments.map_unprotected`
- Produces: `details` は `{ escaped: Integer }`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "test_helper"

class FeedFilters::PreParse::BareAmpersandEscaperTest < ActiveSupport::TestCase
  def run_filter(xml)
    filter = FeedFilters::PreParse::BareAmpersandEscaper.new
    out = filter.applicable?(xml) ? filter.apply(xml) : xml
    [ out, filter ]
  end

  test "文字参照になっていない & を本文と属性の両方で &amp; にする" do
    out, filter = run_filter(%(<a href="/?a=1&b=2">Q & A &</a>))
    assert_equal %(<a href="/?a=1&amp;b=2">Q &amp; A &amp;</a>), out
    assert_equal({ escaped: 3 }, filter.details)
  end

  test "文字参照の形になっているものはそのまま" do
    xml = "<a>&amp;&foo;&#65;&#x41;</a>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "大文字の X の文字参照は XML では不正なのでエスケープする" do
    out, = run_filter("<a>&#X41;</a>")
    assert_equal "<a>&amp;#X41;</a>", out
  end

  test "CDATA の中の & はそのまま" do
    xml = "<a><![CDATA[a & b]]></a>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end
end
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose run --rm web rails test test/services/feed_filters/pre_parse/bare_ampersand_escaper_test.rb`
Expected: FAIL (`uninitialized constant`)

- [ ] **Step 3: 実装する**

```ruby
module FeedFilters
  module PreParse
    # 文字参照の形 (&name; / &#123; / &#x1F;) になっていない & を &amp; にする。
    # URL のクエリ (?a=1&b=2) をエスケープせずに書いたフィードで、libxml2 がそこで読むのをやめるのを防ぐ。
    class BareAmpersandEscaper < Base
      BARE_AMP = /&(?!(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#x[0-9A-Fa-f]+);)/

      def applicable?(xml_content, metadata = {})
        xml_content.include?("&")
      end

      def apply(xml_content, metadata = {})
        escaped = 0

        fixed = XmlSegments.map_unprotected(xml_content) do |text|
          text.gsub(BARE_AMP) do
            escaped += 1
            "&amp;"
          end
        end

        mark_as_applied!(escaped: escaped) if escaped > 0
        fixed
      end
    end
  end
end
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: 同上
Expected: PASS

- [ ] **Step 5: rubocop を通してコミット**

```bash
docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/services/feed_filters test/services/feed_filters
git add app/services/feed_filters/pre_parse/bare_ampersand_escaper.rb test/services/feed_filters/pre_parse/bare_ampersand_escaper_test.rb
git commit -m "素の&をエスケープするBareAmpersandEscaperを追加"
```

### Task 5: LocalizedDateFixer (Ruby)

**Files:**
- Create: `app/services/feed_filters/pre_parse/localized_date_fixer.rb`
- Test: `test/services/feed_filters/pre_parse/localized_date_fixer_test.rb`

**Interfaces:**
- Consumes: `XmlSegments.map_unprotected`
- Produces: `details` は `{ fixed: Integer }`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "test_helper"

class FeedFilters::PreParse::LocalizedDateFixerTest < ActiveSupport::TestCase
  def run_filter(xml)
    filter = FeedFilters::PreParse::LocalizedDateFixer.new
    out = filter.applicable?(xml) ? filter.apply(xml) : xml
    [ out, filter ]
  end

  test "曜日と月が日本語の日時を英語の表記に直す" do
    xml = "<item><pubDate>金, 25 9月 2026 16:07:00 GMT</pubDate>" \
          "<dc:date>木, 1 10月 2026 01:02:03 GMT</dc:date>" \
          "<lastBuildDate>26 12月 2026</lastBuildDate>" \
          "<pubDate>月, 5 1月 2026 04:10:00 +0900</pubDate></item>"
    out, filter = run_filter(xml)
    assert_equal "<item><pubDate>25 Sep 2026 16:07:00 GMT</pubDate>" \
                 "<dc:date>1 Oct 2026 01:02:03 GMT</dc:date>" \
                 "<lastBuildDate>26 Dec 2026</lastBuildDate>" \
                 "<pubDate>5 Jan 2026 04:10:00 +0900</pubDate></item>", out
    assert_equal({ fixed: 4 }, filter.details)
  end

  test "英語の日時と、日時の要素以外の「月」には手を入れない" do
    xml = "<item><title>9月の予定 25 9月 2026</title><pubDate>Fri, 25 Sep 2026 16:07:00 GMT</pubDate></item>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "13月のような存在しない月はそのまま" do
    xml = "<pubDate>1 13月 2026</pubDate>"
    out, filter = run_filter(xml)
    assert_equal xml, out
    assert_not filter.applied
  end

  test "直したあとの日時を DateTime.parse が正しく読める" do
    out, = run_filter("<pubDate>木, 1 10月 2026 01:02:03 GMT</pubDate>")
    date = out[%r{<pubDate>(.*)</pubDate>}, 1]
    assert_equal Time.utc(2026, 10, 1, 1, 2, 3), DateTime.parse(date).to_time.utc
  end
end
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose run --rm web rails test test/services/feed_filters/pre_parse/localized_date_fixer_test.rb`
Expected: FAIL (`uninitialized constant`)

- [ ] **Step 3: 実装する**

```ruby
module FeedFilters
  module PreParse
    # 「金, 25 9月 2026 16:07:00 GMT」のように曜日と月を日本語にした日時を英語の表記に直す。
    # 日本からアクセスすると検索エンジンのフィードがこの形で返すことがあり、Ruby の DateTime.parse は
    # 10〜12月を読み違え (1 10月 → 9月10日)、1月は読めない。
    # Rust 版と同じ結果にするため、\d や \s ではなく [0-9] と [ \t\r\n] を使う。
    class LocalizedDateFixer < Base
      DATE_ELEMENT = /<(pubDate|lastBuildDate|dc:date)>([^<]*)</
      JA_DATE = /\A([ \t\r\n]*)(?:[日月火水木金土],[ \t\r\n]*)?([0-9]{1,2})[ \t\r\n]+([0-9]{1,2})月[ \t\r\n]+([0-9]{4}(?:[ \t\r\n].*)?)\z/m
      MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze

      def applicable?(xml_content, metadata = {})
        xml_content.include?("月")
      end

      def apply(xml_content, metadata = {})
        fixed_count = 0

        fixed = XmlSegments.map_unprotected(xml_content) do |text|
          text.gsub(DATE_ELEMENT) do |whole|
            tag = $1
            date = JA_DATE.match($2)
            month = date && date[3].to_i
            next whole unless date && (1..12).cover?(month)

            fixed_count += 1
            "<#{tag}>#{date[1]}#{date[2]} #{MONTHS[month - 1]} #{date[4]}<"
          end
        end

        mark_as_applied!(fixed: fixed_count) if fixed_count > 0
        fixed
      end
    end
  end
end
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: 同上
Expected: PASS

- [ ] **Step 5: rubocop を通してコミット**

```bash
docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/services/feed_filters test/services/feed_filters
git add app/services/feed_filters/pre_parse/localized_date_fixer.rb test/services/feed_filters/pre_parse/localized_date_fixer_test.rb
git commit -m "曜日と月が日本語の日時を英語の表記に直すLocalizedDateFixerを追加"
```

### Task 6: FeedNormalizer にフィルタを並べ、例外で止まらないようにする (Ruby)

**Files:**
- Modify: `app/services/feed_normalizer.rb` (`PRE_PARSE_FILTERS` と `apply_pre_parse_filters`)
- Test: `test/services/feed_normalizer_test.rb` (テストを追加)

**Interfaces:**
- Consumes: Task 2〜5 のフィルタ
- Produces: `FeedNormalizer.normalize_and_parse(raw_xml, feed_url)` の戻り値は今までどおり `{ feed:, applied_filters:, filter_details: }`

- [ ] **Step 1: 失敗するテストを追加する**

`test/services/feed_normalizer_test.rb` の末尾 (最後の `end` の前) に足す:

```ruby
  test "壊れたところを直して、すべての entry を読めるようにする" do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Broken Feed</title>
          <link>https://example.com/</link>
          <item><title>one&nbsp;1</title><link>https://example.com/1</link><guid>1</guid><pubDate>金, 25 9月 2026 16:07:00 GMT</pubDate></item>
          <item><title>two</title><link>https://example.com/2?a=1&b=2</link><guid>2</guid><pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate></item>
          <item><title>three\u0008</title><link>https://example.com/3</link><guid>3</guid><pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate></item>
          <item><title>four</title><link>https://example.com/4</link><guid>4</guid><pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate></item>
        </channel>
      </rss>
    XML

    result = FeedNormalizer.normalize_and_parse(xml, "https://example.com/feed.xml")

    assert_equal %w[1 2 3 4], result[:feed].entries.map(&:entry_id)
    assert_equal "one 1", result[:feed].entries[0].title
    assert_equal "https://example.com/2?a=1&b=2", result[:feed].entries[1].url
    assert_equal Time.utc(2026, 9, 25, 16, 7, 0), result[:feed].entries[0].published
    assert_equal %w[InvalidXmlCharRemover HtmlEntityFixer BareAmpersandEscaper LocalizedDateFixer],
                 result[:applied_filters]
  end

  test "フィルタが例外を出しても、そのフィルタを飛ばして読み進める" do
    FeedFilters::PreParse::HtmlEntityFixer.any_instance.stubs(:apply).raises(RuntimeError, "boom")
    Sentry.expects(:capture_exception).once
    xml = %(<?xml version="1.0"?><rss version="2.0"><channel><title>t&amp;u</title><link>https://example.com/</link></channel></rss>)

    result = FeedNormalizer.normalize_and_parse(xml, "https://example.com/feed.xml")

    assert_equal "t&u", result[:feed].title
    assert_not_includes result[:applied_filters], "HtmlEntityFixer"
  end
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose run --rm web rails test test/services/feed_normalizer_test.rb`
Expected: FAIL (entry が途中で切れる / 例外がそのまま上がる)

- [ ] **Step 3: 実装する**

`app/services/feed_normalizer.rb` の `PRE_PARSE_FILTERS` を置き換える:

```ruby
  # Pre-parseフィルタ（XML文字列に対して適用）。順番に意味がある:
  # 使えない文字を消す → 名前付きエンティティを直す → 残った素の&を直す → 日時を直す
  PRE_PARSE_FILTERS = [
    FeedFilters::PreParse::InvalidXmlCharRemover,
    FeedFilters::PreParse::HtmlEntityFixer,
    FeedFilters::PreParse::BareAmpersandEscaper,
    FeedFilters::PreParse::LocalizedDateFixer,
    FeedFilters::PreParse::AtomNamespaceFixer
  ].freeze
```

`apply_pre_parse_filters` を置き換える:

```ruby
  def apply_pre_parse_filters(xml_content)
    normalized_xml = xml_content

    PRE_PARSE_FILTERS.each do |filter_class|
      filter = filter_class.new
      metadata = { feed_url: @feed_url }

      begin
        next unless filter.applicable?(normalized_xml, metadata)

        Rails.logger.info "[FeedNormalizer] Applying pre-parse filter: #{filter_class.name}"
        normalized_xml = filter.apply(normalized_xml, metadata)

        if filter.applied
          @applied_filters << filter_class.name.demodulize
          @filter_details[filter_class.name.demodulize] = filter.details
        end
      rescue StandardError => e
        # フィルタのバグで取り込み全体を止めない。直す前の文字列のまま次のフィルタに進む
        Rails.logger.error "[FeedNormalizer] Pre-parse filter #{filter_class.name} failed: #{e.class}: #{e.message}"
        Sentry.capture_exception(e, extra: { feed_url: @feed_url, filter: filter_class.name })
      end
    end

    normalized_xml
  end
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `docker compose run --rm web rails test test/services/feed_normalizer_test.rb test/services/feed_filters`
Expected: PASS

- [ ] **Step 5: rubocop を通してコミット**

```bash
docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/services test/services
git add app/services/feed_normalizer.rb test/services/feed_normalizer_test.rb
git commit -m "FeedNormalizerに壊れたフィードを直すフィルタを並べ、フィルタの例外で取り込みを止めない"
```

### Task 7: RelativeUrlResolver をフィードの URL 基準にし、前後の空白を無視する (Ruby)

**Files:**
- Modify: `app/services/feed_filters/post_parse/relative_url_resolver.rb`
- Modify: `test/services/feed_filters/post_parse/relative_url_resolver_test.rb`

**Interfaces:**
- Produces: `details[:base_url]` はフィードの URL そのもの (以前は `scheme://host[:port]`)

- [ ] **Step 1: 失敗するテストを追加する**

`test/services/feed_filters/post_parse/relative_url_resolver_test.rb` の `private` より前に足す:

```ruby
  test "フィードの URL を基準に RFC 3986 のとおり解決する" do
    feed = create_mock_feed(
      feed_url: "/",
      entries: [
        { url: "/post/1", title: "abs path" },
        { url: "post/2", title: "rel path" },
        { url: "../post/3", title: "parent" },
        { url: "?page=2", title: "query only" }
      ]
    )

    result = @filter.apply(feed, { feed_url: "https://example.com/blog/feed.xml" })

    assert_equal "https://example.com/", result.url
    assert_equal "https://example.com/post/1", result.entries[0].url
    assert_equal "https://example.com/blog/post/2", result.entries[1].url
    assert_equal "https://example.com/post/3", result.entries[2].url
    assert_equal "https://example.com/blog/feed.xml?page=2", result.entries[3].url
    assert_equal "https://example.com/blog/feed.xml", @filter.details[:base_url]
  end

  test "前後に改行がある絶対 URL は相対 URL とみなさず、書き換えない" do
    feed = create_mock_feed(
      feed_url: "https://example.com/",
      entries: [ { url: "\n  https://example.com/post/1\n", title: "newline" } ]
    )

    assert_not @filter.applicable?(feed, { feed_url: "https://example.com/feed.xml" })
    assert_equal "\n  https://example.com/post/1\n", feed.entries[0].url
  end

  test "前後に改行がある相対 URL は、取り除いてから解決する" do
    feed = create_mock_feed(
      feed_url: "https://example.com/",
      entries: [ { url: "\n/post/1\n", title: "newline" } ]
    )

    result = @filter.apply(feed, { feed_url: "https://example.com/feed.xml" })

    assert_equal "https://example.com/post/1", result.entries[0].url
  end
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose run --rm web rails test test/services/feed_filters/post_parse/relative_url_resolver_test.rb`
Expected: FAIL (`https://example.com/post/2` になる、改行入りを相対とみなす、など)

- [ ] **Step 3: 実装する**

`apply` の中の `base_url = extract_base_url(feed_url)` を `base_url = feed_url` に変える。`private` 以下を次に置き換える (`extract_base_url` は消す):

```ruby
      private

      # 前後の空白・改行は取り除いてから判定する (<link> の中身が改行で始まるフィードがある)
      def has_relative_url?(url)
        return false if url.blank?

        !url.to_s.strip.start_with?("http://", "https://")
      end

      # フィードの URL を基準に RFC 3986 のとおり解決する
      def resolve_url(url, base_url)
        Addressable::URI.join(base_url, url.to_s.strip).to_s
      end
```

- [ ] **Step 4: 既存のテストのうち、基準が `scheme://host` であることを前提にしたものを直す**

Run: `docker compose run --rm web rails test test/services/feed_filters/post_parse/relative_url_resolver_test.rb test/services/feed_normalizer_test.rb`

失敗したテストは、期待値を「フィードの URL を基準にした結果」に直す (例: `details[:base_url]` の期待値をフィードの URL に、`extract_base_url` を直接呼ぶテストは削除)。テストの意図 (相対 URL を絶対 URL にする) は変えない。
Expected: 修正後に PASS

- [ ] **Step 5: rubocop を通してコミット**

```bash
docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/services test/services
git add app/services/feed_filters/post_parse/relative_url_resolver.rb test/services/feed_filters/post_parse/relative_url_resolver_test.rb test/services/feed_normalizer_test.rb
git commit -m "RelativeUrlResolverをフィードのURL基準で解決し、前後の空白を無視して判定する"
```

### Task 8: 空の guid を無いものとして扱い、applied_filters の変化を通知しない (Ruby)

**Files:**
- Modify: `app/models/channel.rb` (entry_id を参照している5箇所と `notify_channel_change`)
- Test: `test/models/channel_fetch_and_save_items_test.rb`、`test/models/channel_notification_test.rb`

**Interfaces:**
- Produces: `Channel#entry_id_of(entry)` (private)。`entry.entry_id` が `nil`・`:no_buffer`・空文字なら `nil`、それ以外はそのまま返す

- [ ] **Step 1: 失敗するテストを書く**

`test/models/channel_fetch_and_save_items_test.rb` の `private` より前に足す:

```ruby
  describe "空の guid (Feedjira では :no_buffer になる)" do
    test "entry_id が無いものとして url を guid にする" do
      entries = [
        build_mock_entry(entry_id: :no_buffer, url: "https://example.com/1", title: "one"),
        build_mock_entry(entry_id: :no_buffer, url: "https://example.com/2", title: "two"),
        build_mock_entry(entry_id: "", url: "https://example.com/3", title: "three")
      ]
      stub_feed_with_entries(entries)
      OpenGraph.stubs(:new).returns(OpenStruct.new(image: nil))
      @channel.stubs(:sleep)

      @channel.fetch_and_save_items

      assert_equal %w[https://example.com/1 https://example.com/2 https://example.com/3], @channel.items.order(:guid).pluck(:guid)
    end

    test "既に no_buffer の guid で保存された item があっても、新しい記事を取りこぼさない" do
      @channel.items.create!(guid: "no_buffer", title: "old", url: "https://example.com/old", published_at: 1.day.ago)
      stub_feed_with_entries([ build_mock_entry(entry_id: :no_buffer, url: "https://example.com/new", title: "new") ])
      OpenGraph.stubs(:new).returns(OpenStruct.new(image: nil))
      @channel.stubs(:sleep)

      @channel.fetch_and_save_items

      assert @channel.items.exists?(guid: "https://example.com/new")
    end
  end
```

`test/models/channel_notification_test.rb` の末尾 (最後の `end` の前) に足す:

```ruby
  test "notify_channel_change ignores applied_filters changes" do
    clear_enqueued_jobs

    @channel.update!(applied_filters: [ "HtmlEntityFixer" ], filter_details: { "HtmlEntityFixer" => { replaced: 1 } })

    assert_enqueued_jobs 0, only: DiscoPosterJob
  end
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose run --rm web rails test test/models/channel_fetch_and_save_items_test.rb test/models/channel_notification_test.rb`
Expected: FAIL (guid が `no_buffer` になる / 通知が積まれる)

- [ ] **Step 3: 実装する**

`app/models/channel.rb` の private メソッド群に足す:

```ruby
  # RSS の空の <guid/> は Feedjira (sax-machine) で :no_buffer になるので、無いものとして扱う
  def entry_id_of(entry)
    id = entry.entry_id
    return nil if id.nil? || id == :no_buffer || id.to_s.empty?

    id
  end
```

`fetch_and_save_items` の中の `entry.entry_id` / `_1.entry_id` を、すべて `entry_id_of(...)` に置き換える (5箇所。`grep -n "entry_id" app/models/channel.rb` で確認する):

```ruby
        feed.entries.reject {
          self.items.exists?(guid: entry_id_of(_1)) ||
          self.items.exists?(guid: _1.url)
        }
```

```ruby
    notifiable_guids = feed.entries.select(&:published).sort_by(&:published).last(2).flat_map { [ entry_id_of(_1), _1.url ] }.compact
```

```ruby
        guid = entry_id_of(entry) || entry.url
```

Sentry の `extra` にある `item_guid: entry.entry_id || entry.url` (2箇所) も `item_guid: entry_id_of(entry) || entry.url` にする。

`exists?(guid: nil)` は `guid IS NULL` になり、guid は NOT NULL なので常に false になる。これで `no_buffer` の既存 item と誤って一致しなくなる。

`notify_channel_change` の `ignored_fields` に `applied_filters` を足す:

```ruby
    # last_items_checked_at・updated_at・フィルタの適用状況の変更は無視する
    ignored_fields = %w[last_items_checked_at applied_filters filter_details updated_at created_at]
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `docker compose run --rm web rails test test/models`
Expected: PASS

- [ ] **Step 5: rubocop を通してコミット**

```bash
docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/models/channel.rb test/models
git add app/models/channel.rb test/models/channel_fetch_and_save_items_test.rb test/models/channel_notification_test.rb
git commit -m "空のguidをentry_id無しとして扱い、applied_filtersの変化をチャンネル変更通知の対象から外す"
```

### Task 9: Rails 側の全体確認・PR・デプロイ (デプロイはユーザーが行う)

**Files:** なし (確認と PR のみ)

- [ ] **Step 1: Rails のテスト全体と rubocop を通す**

Run:
```bash
docker compose run --rm web rails test
docker compose run --rm web bundle exec rubocop -c .rubocop.yml
```
Expected: どちらも失敗 0

- [ ] **Step 2: PR を作る**

```bash
git push -u origin design/feed-repair-filters
```

`gh pr create` で PR を作る。本文には「Rust の fetcher は別の PR (Part 2) で追従する。golden はこの PR では作り直さない (作り直すと Rust の golden テストが落ちるため)」と書く。

- [ ] **Step 3: ユーザーにマージとデプロイを依頼し、観察する**

マージとデプロイはユーザーが行う。デプロイ後、翌日までに次を一緒に確認する:
- Sentry に新しいエラーが出ていないか (`sentry-cli issues list --status unresolved`)
- `heroku pg:psql` (読み取り専用) で、新しいフィルタが `applied_filters` に付いたチャンネルの数

## Part 2: Rust

作業ブランチは Part 1 のマージ後に `main` から `feat/fetcher-repair-filters` を切る。

### Task 10: 合成フィクスチャを足し、フィルタ入りの Rails で golden を作り直す

**Files:**
- Create: `fetcher/testdata/fixtures/rss_repair_entities.xml`
- Create: `fetcher/testdata/fixtures/rss_localized_dates.xml`
- Create: `fetcher/testdata/fixtures/rss_link_whitespace_and_empty_guid.xml`
- Create: `fetcher/testdata/fixtures/rss_relative_urls_subdir.xml`、`fetcher/testdata/fixtures/rss_relative_urls_subdir.url`
- Modify: `fetcher/testdata/fixtures/*.golden.json` (Rails で作り直す)

**Interfaces:**
- Produces: フィルタ入りの Rails で作った golden (Task 11〜13 の Rust が一致させる対象)。Rust の golden テストは Task 13 まで一部が落ちたままになる

- [ ] **Step 1: 合成フィクスチャを作る**

`fetcher/testdata/fixtures/rss_repair_entities.xml` (制御文字 `\x08` を含むので printf で書く):

```bash
printf '%s\n' \
'<?xml version="1.0" encoding="UTF-8"?>' \
'<rss version="2.0">' \
'  <channel>' \
'    <title>Repair Entities RSS</title>' \
'    <link>https://example.com/repair</link>' \
'    <description>entities &amp; ampersands</description>' \
'    <copyright>&copy; 2026 Example</copyright>' \
'    <item>' \
'      <title>nbsp&nbsp;and&hellip;</title>' \
'      <link>https://example.com/1?a=1&b=2</link>' \
'      <guid isPermaLink="false">one</guid>' \
'      <pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate>' \
'      <description>unknown &foo; and bare & and ctrl&#8; ref</description>' \
'      <enclosure url="https://example.com/a.mp3?x=1&y=2" length="1" type="audio/mpeg"/>' \
'    </item>' \
"      <item><title>ctrl$(printf '\010')char</title><link>https://example.com/2</link><guid isPermaLink=\"false\">two</guid><pubDate>Wed, 24 Sep 2026 01:00:00 +0000</pubDate><description><![CDATA[keep & and &nbsp; as is]]></description></item>" \
'    <item>' \
'      <title>after</title>' \
'      <link>https://example.com/3</link>' \
'      <guid isPermaLink="false">three</guid>' \
'      <pubDate>Wed, 24 Sep 2026 02:00:00 +0000</pubDate>' \
'    </item>' \
'  </channel>' \
'</rss>' > fetcher/testdata/fixtures/rss_repair_entities.xml
```

`fetcher/testdata/fixtures/rss_localized_dates.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Localized Dates RSS</title>
    <link>https://example.com/dates</link>
    <description>dates in Japanese</description>
    <item><title>sep</title><link>https://example.com/sep</link><guid isPermaLink="false">sep</guid><pubDate>金, 25 9月 2026 16:07:00 GMT</pubDate></item>
    <item><title>oct</title><link>https://example.com/oct</link><guid isPermaLink="false">oct</guid><pubDate>木, 1 10月 2026 01:02:03 GMT</pubDate></item>
    <item><title>dec</title><link>https://example.com/dec</link><guid isPermaLink="false">dec</guid><pubDate>土, 26 12月 2026 04:10:00 +0900</pubDate></item>
    <item><title>jan</title><link>https://example.com/jan</link><guid isPermaLink="false">jan</guid><pubDate>月, 5 1月 2026 04:10:00 GMT</pubDate></item>
  </channel>
</rss>
```

`fetcher/testdata/fixtures/rss_link_whitespace_and_empty_guid.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Link Whitespace RSS</title>
    <link>https://example.com/ws</link>
    <description>newline in link and empty guid</description>
    <item>
      <title>newline link with guid</title>
      <link>
        https://example.com/ws/1
      </link>
      <guid isPermaLink="false">ws-1</guid>
      <pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate>
    </item>
    <item>
      <title>empty guid a</title>
      <link>https://example.com/ws/2</link>
      <guid/>
      <pubDate>Wed, 24 Sep 2026 01:00:00 +0000</pubDate>
    </item>
    <item>
      <title>empty guid b</title>
      <link>https://example.com/ws/3</link>
      <guid></guid>
      <pubDate>Wed, 24 Sep 2026 02:00:00 +0000</pubDate>
    </item>
  </channel>
</rss>
```

`fetcher/testdata/fixtures/rss_relative_urls_subdir.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Relative Subdir RSS</title>
    <link>./</link>
    <description>relative urls against a feed in a subdirectory</description>
    <item><title>abs path</title><link>/post/1</link><guid isPermaLink="false">r1</guid><pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate></item>
    <item><title>rel path</title><link>post/2</link><guid isPermaLink="false">r2</guid><pubDate>Wed, 24 Sep 2026 01:00:00 +0000</pubDate></item>
    <item><title>parent</title><link>../post/3</link><guid isPermaLink="false">r3</guid><pubDate>Wed, 24 Sep 2026 02:00:00 +0000</pubDate></item>
    <item><title>query</title><link>?page=2</link><guid isPermaLink="false">r4</guid><pubDate>Wed, 24 Sep 2026 03:00:00 +0000</pubDate></item>
    <item><title>no guid</title><link>post/5</link><pubDate>Wed, 24 Sep 2026 04:00:00 +0000</pubDate></item>
  </channel>
</rss>
```

```bash
echo "https://example.com/blog/feed.xml" > fetcher/testdata/fixtures/rss_relative_urls_subdir.url
```

- [ ] **Step 2: フィルタ入りの Rails で golden を作り直し、差分を確かめる**

Run:
```bash
docker compose run --rm -e RAILS_ENV=test web rails "fetcher:golden[fetcher/testdata/fixtures]"
git diff --stat fetcher/testdata/fixtures
jq -c '[.entries[].guid]' fetcher/testdata/fixtures/rss_repair_entities.golden.json \
  fetcher/testdata/fixtures/rss_undefined_entity.golden.json \
  fetcher/testdata/fixtures/rss_link_whitespace_and_empty_guid.golden.json
jq -c '[.entries[].published_at]' fetcher/testdata/fixtures/rss_localized_dates.golden.json
jq -c '[.entries[].url]' fetcher/testdata/fixtures/rss_relative_urls_subdir.golden.json
jq -c '.applied_filters' fetcher/testdata/fixtures/*.golden.json | sort | uniq -c
```

Expected:
- `rss_repair_entities`: `["one","two","three"]`。`rss_undefined_entity`: before/entity/after の3件
- `rss_link_whitespace_and_empty_guid`: `ws-1`、`https://example.com/ws/2`、`https://example.com/ws/3`
- `rss_localized_dates`: `2026-09-25T16:07:00Z`、`2026-10-01T01:02:03Z`、`2026-12-25T19:10:00Z`、`2026-01-05T04:10:00Z` (published_at 順)
- `rss_relative_urls_subdir`: `https://example.com/post/1`、`https://example.com/blog/post/2`、`https://example.com/post/3`、`https://example.com/blog/feed.xml?page=2`、`https://example.com/blog/post/5`
- 変更が出るのは、壊れたフィードのフィクスチャ (`rss_undefined_entity`、`rss_attr_bare_amp`、`atom_content_bare_amp`、`rss_invalid_xml_char`、`rss_entity_copyright`) と、`applied_filters` が変わるものだけ。それ以外の golden に差分が出たら、理由を調べて報告する

- [ ] **Step 3: 本番フィードのコーパスでも Rails の golden を作り直す (コミットしない)**

Run:
```bash
docker compose run --rm -e RAILS_ENV=test web rails "fetcher:golden[fetcher/testdata/corpus]"
```
Expected: `FAILED` が作り直す前より増えない

- [ ] **Step 4: コミットする**

```bash
git add fetcher/testdata/fixtures/rss_repair_entities.xml fetcher/testdata/fixtures/rss_localized_dates.xml \
  fetcher/testdata/fixtures/rss_link_whitespace_and_empty_guid.xml \
  fetcher/testdata/fixtures/rss_relative_urls_subdir.xml fetcher/testdata/fixtures/rss_relative_urls_subdir.url \
  fetcher/testdata/fixtures/*.golden.json
git commit -m "壊れたフィードの合成フィクスチャを足し、フィルタ入りのRailsでgoldenを作り直す"
```

### Task 11: 書き換え範囲の切り出しとエンティティ表 (Rust)

**Files:**
- Create: `fetcher/src/filters/segments.rs`
- Create: `fetcher/src/filters/html_entities.rs`
- Modify: `fetcher/src/filters/mod.rs` (`pub mod` を足す)

**Interfaces:**
- Produces: `filters::segments::map_unprotected(xml: &str, f: impl FnMut(&str) -> String) -> String`
- Produces: `filters::html_entities::lookup(name: &str) -> Option<&'static str>`

- [ ] **Step 1: 失敗するテストを書く**

`fetcher/src/filters/segments.rs`:

```rust
//! XML 文字列を「書き換えてよい部分」と「CDATA・コメント・処理命令・DOCTYPE」に分け、
//! 書き換えてよい部分だけを変換してつなぎ直す。Ruby 版 (FeedFilters::PreParse::XmlSegments) と同じ正規表現。

#[cfg(test)]
mod tests {
    use super::*;

    fn upcase_outside(xml: &str) -> String {
        map_unprotected(xml, |t| t.to_uppercase())
    }

    #[test]
    fn protected_sections_are_left_as_is() {
        let xml = r#"<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x "y">]><a>b<![CDATA[c & d]]>e<!-- f --></a>"#;
        assert_eq!(
            upcase_outside(xml),
            r#"<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x "y">]><A>B<![CDATA[c & d]]>E<!-- f --></A>"#
        );
    }

    #[test]
    fn whole_text_without_sections() {
        assert_eq!(upcase_outside("<a>b</a>"), "<A>B</A>");
    }

    #[test]
    fn unterminated_cdata_is_rewritable() {
        assert_eq!(upcase_outside("<a><![CDATA[b"), "<A><![CDATA[B");
    }
}
```

`fetcher/src/filters/html_entities.rs`:

```rust
//! WHATWG の名前付き文字参照の表。Rails と同じ JSON をリポジトリから埋め込む。

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn looks_up_by_name_without_ampersand_and_semicolon() {
        assert_eq!(lookup("nbsp"), Some("\u{a0}"));
        assert_eq!(lookup("copy"), Some("©"));
        assert_eq!(lookup("nbsp;"), None);
    }
}
```

`fetcher/src/filters/mod.rs` の先頭に `pub mod html_entities;` と `pub mod segments;` を足す。

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `cd fetcher && cargo test --lib filters::segments filters::html_entities`
Expected: FAIL (`cannot find function map_unprotected` / `lookup`)

- [ ] **Step 3: 実装する**

`segments.rs` のテストの上に:

```rust
use std::sync::LazyLock;

use regex::Regex;

static PROTECTED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|<!DOCTYPE[^\[>]*(?:\[.*?\])?[ \t\r\n]*>")
        .unwrap()
});

pub fn map_unprotected(xml: &str, mut f: impl FnMut(&str) -> String) -> String {
    let mut out = String::with_capacity(xml.len());
    let mut pos = 0;
    for m in PROTECTED.find_iter(xml) {
        out.push_str(&f(&xml[pos..m.start()]));
        out.push_str(m.as_str());
        pos = m.end();
    }
    out.push_str(&f(&xml[pos..]));
    out
}
```

`html_entities.rs` のテストの上に:

```rust
use std::collections::HashMap;
use std::sync::LazyLock;

static TABLE: LazyLock<HashMap<String, String>> = LazyLock::new(|| {
    serde_json::from_str(include_str!(
        "../../../app/services/feed_filters/data/html_entities.json"
    ))
    .expect("html_entities.json は名前 → 文字列の JSON")
});

pub fn lookup(name: &str) -> Option<&'static str> {
    TABLE.get(name).map(String::as_str)
}
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `cd fetcher && cargo test --lib filters::segments filters::html_entities`
Expected: PASS

- [ ] **Step 5: fmt/clippy を通してコミット**

```bash
cd fetcher && cargo fmt && cargo clippy --all-targets -- -D warnings && cd ..
git add fetcher/src/filters/segments.rs fetcher/src/filters/html_entities.rs fetcher/src/filters/mod.rs
git commit -m "fetcherにXMLの書き換え範囲の切り出しと、Railsと共有するエンティティ表を追加"
```

### Task 12: 4つのパース前フィルタと並び順 (Rust)

**Files:**
- Create: `fetcher/src/filters/invalid_xml_char_remover.rs`
- Modify: `fetcher/src/filters/html_entity_fixer.rs` (全体を置き換え)
- Create: `fetcher/src/filters/bare_ampersand_escaper.rs`
- Create: `fetcher/src/filters/localized_date_fixer.rs`
- Modify: `fetcher/src/filters/mod.rs` (`apply_pre_parse` の並び)
- Modify: `fetcher/src/parse/date.rs` (`englishize_japanese` と関連するテストを削除)

**Interfaces:**
- Consumes: `segments::map_unprotected`、`html_entities::lookup`
- Produces: `PreParseFilter` を実装した `InvalidXmlCharRemover` / `HtmlEntityFixer` / `BareAmpersandEscaper` / `LocalizedDateFixer`。`name()` は Ruby のクラス名と同じ

- [ ] **Step 1: 失敗するテストを書く (Ruby の Task 2〜5 と同じ入力と期待値)**

`fetcher/src/filters/invalid_xml_char_remover.rs`:

```rust
//! XML 1.0 で使えない文字を取り除く (Ruby の InvalidXmlCharRemover)。

#[cfg(test)]
mod tests {
    use super::*;

    fn run(xml: &str) -> (String, Option<serde_json::Value>) {
        match InvalidXmlCharRemover.apply(xml) {
            Some((out, d)) => (out, Some(d)),
            None => (xml.to_string(), None),
        }
    }

    #[test]
    fn removes_raw_chars_everywhere() {
        let (out, d) = run("<a>x\u{8}y<![CDATA[p\u{1}q]]>\u{fffe}</a>");
        assert_eq!(out, "<a>xy<![CDATA[pq]]></a>");
        assert_eq!(d.unwrap(), serde_json::json!({"removed_chars": 3, "removed_refs": 0}));
    }

    #[test]
    fn removes_invalid_char_refs_outside_cdata() {
        let (out, d) = run(r#"<a b="&#x1F;">&#8;&#xD800;&#1114112;<![CDATA[&#8;]]></a>"#);
        assert_eq!(out, r#"<a b=""><![CDATA[&#8;]]></a>"#);
        assert_eq!(d.unwrap(), serde_json::json!({"removed_chars": 0, "removed_refs": 4}));
    }

    #[test]
    fn keeps_allowed_chars_and_refs() {
        let (out, d) = run("<a>\t\n\r&#9;&#xA;&#x3042;&#65;</a>");
        assert_eq!(out, "<a>\t\n\r&#9;&#xA;&#x3042;&#65;</a>");
        assert!(d.is_none());
    }
}
```

`fetcher/src/filters/html_entity_fixer.rs` (今のファイルを消して、この内容から始める):

```rust
//! 名前付きのエンティティを直す (Ruby の HtmlEntityFixer)。

#[cfg(test)]
mod tests {
    use super::*;

    fn run(xml: &str) -> (String, Option<serde_json::Value>) {
        match HtmlEntityFixer.apply(xml) {
            Some((out, d)) => (out, Some(d)),
            None => (xml.to_string(), None),
        }
    }

    #[test]
    fn replaces_html_entities_in_text_and_attributes() {
        let (out, d) = run(r#"<a href="/?x=&nbsp;">&copy; 2026&hellip;</a>"#);
        assert_eq!(out, r#"<a href="/?x=&#xA0;">&#xA9; 2026&#x2026;</a>"#);
        assert_eq!(d.unwrap(), serde_json::json!({"replaced": 3, "unknown": 0}));
    }

    #[test]
    fn two_codepoint_entities() {
        assert_eq!(run("<a>&NotEqualTilde;</a>").0, "<a>&#x2242;&#x338;</a>");
    }

    #[test]
    fn unknown_names_become_literal() {
        let (out, d) = run("<a>&foo; &bar;</a>");
        assert_eq!(out, "<a>&amp;foo; &amp;bar;</a>");
        assert_eq!(d.unwrap(), serde_json::json!({"replaced": 0, "unknown": 2}));
    }

    #[test]
    fn predefined_and_numeric_refs_are_kept() {
        let xml = "<a>&amp;&lt;&gt;&quot;&apos;&#65;&#x41;</a>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }

    #[test]
    fn cdata_and_comments_are_kept() {
        let xml = "<a><![CDATA[&nbsp;]]><!-- &copy; --></a>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }

    #[test]
    fn documents_declaring_entities_are_skipped() {
        let xml = r#"<!DOCTYPE rss [<!ENTITY myent "x">]><a>&myent;&nbsp;</a>"#;
        assert_eq!(run(xml), (xml.to_string(), None));
    }
}
```

`fetcher/src/filters/bare_ampersand_escaper.rs`:

```rust
//! 文字参照の形になっていない & を &amp; にする (Ruby の BareAmpersandEscaper)。

#[cfg(test)]
mod tests {
    use super::*;

    fn run(xml: &str) -> (String, Option<serde_json::Value>) {
        match BareAmpersandEscaper.apply(xml) {
            Some((out, d)) => (out, Some(d)),
            None => (xml.to_string(), None),
        }
    }

    #[test]
    fn escapes_bare_ampersands() {
        let (out, d) = run(r#"<a href="/?a=1&b=2">Q & A &</a>"#);
        assert_eq!(out, r#"<a href="/?a=1&amp;b=2">Q &amp; A &amp;</a>"#);
        assert_eq!(d.unwrap(), serde_json::json!({"escaped": 3}));
    }

    #[test]
    fn keeps_refs() {
        let xml = "<a>&amp;&foo;&#65;&#x41;</a>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }

    #[test]
    fn uppercase_x_is_not_a_char_ref() {
        assert_eq!(run("<a>&#X41;</a>").0, "<a>&amp;#X41;</a>");
    }

    #[test]
    fn cdata_is_kept() {
        let xml = "<a><![CDATA[a & b]]></a>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }
}
```

`fetcher/src/filters/localized_date_fixer.rs`:

```rust
//! 曜日と月が日本語の日時を英語の表記に直す (Ruby の LocalizedDateFixer)。

#[cfg(test)]
mod tests {
    use super::*;

    fn run(xml: &str) -> (String, Option<serde_json::Value>) {
        match LocalizedDateFixer.apply(xml) {
            Some((out, d)) => (out, Some(d)),
            None => (xml.to_string(), None),
        }
    }

    #[test]
    fn rewrites_japanese_dates() {
        let xml = "<item><pubDate>金, 25 9月 2026 16:07:00 GMT</pubDate>\
                   <dc:date>木, 1 10月 2026 01:02:03 GMT</dc:date>\
                   <lastBuildDate>26 12月 2026</lastBuildDate>\
                   <pubDate>月, 5 1月 2026 04:10:00 +0900</pubDate></item>";
        let (out, d) = run(xml);
        assert_eq!(
            out,
            "<item><pubDate>25 Sep 2026 16:07:00 GMT</pubDate>\
             <dc:date>1 Oct 2026 01:02:03 GMT</dc:date>\
             <lastBuildDate>26 Dec 2026</lastBuildDate>\
             <pubDate>5 Jan 2026 04:10:00 +0900</pubDate></item>"
        );
        assert_eq!(d.unwrap(), serde_json::json!({"fixed": 4}));
    }

    #[test]
    fn leaves_english_dates_and_other_elements() {
        let xml = "<item><title>9月の予定 25 9月 2026</title><pubDate>Fri, 25 Sep 2026 16:07:00 GMT</pubDate></item>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }

    #[test]
    fn leaves_invalid_month() {
        let xml = "<pubDate>1 13月 2026</pubDate>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }
}
```

`fetcher/src/filters/mod.rs` の先頭に `pub mod bare_ampersand_escaper;`、`pub mod invalid_xml_char_remover;`、`pub mod localized_date_fixer;` を足す。

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `cd fetcher && cargo test --lib filters`
Expected: FAIL (未定義の型)

- [ ] **Step 3: 実装する**

`invalid_xml_char_remover.rs` のテストの上に:

```rust
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Value, json};

use super::PreParseFilter;
use super::segments::map_unprotected;

static CHAR_REF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"&#(?:x([0-9A-Fa-f]+)|([0-9]+));").unwrap());

fn is_xml_char_code(code: u64) -> bool {
    matches!(code, 0x9 | 0xA | 0xD | 0x20..=0xD7FF | 0xE000..=0xFFFD | 0x10000..=0x10FFFF)
}

fn is_invalid_char(c: char) -> bool {
    matches!(c, '\u{0}'..='\u{8}' | '\u{b}' | '\u{c}' | '\u{e}'..='\u{1f}' | '\u{fffe}' | '\u{ffff}')
}

pub struct InvalidXmlCharRemover;

impl PreParseFilter for InvalidXmlCharRemover {
    fn name(&self) -> &'static str {
        "InvalidXmlCharRemover"
    }

    fn apply(&self, xml: &str) -> Option<(String, Value)> {
        let mut removed_chars = 0;
        let without_chars: String = xml
            .chars()
            .filter(|&c| {
                let invalid = is_invalid_char(c);
                if invalid {
                    removed_chars += 1;
                }
                !invalid
            })
            .collect();
        let mut removed_refs = 0;
        let fixed = map_unprotected(&without_chars, |text| {
            CHAR_REF
                .replace_all(text, |c: &regex::Captures| {
                    // 桁が多すぎて u64 に収まらないものも、使えない文字として扱う
                    let code = match (c.get(1), c.get(2)) {
                        (Some(h), _) => u64::from_str_radix(h.as_str(), 16).ok(),
                        (_, Some(d)) => d.as_str().parse::<u64>().ok(),
                        _ => None,
                    };
                    if code.is_some_and(is_xml_char_code) {
                        c[0].to_string()
                    } else {
                        removed_refs += 1;
                        String::new()
                    }
                })
                .into_owned()
        });
        (removed_chars + removed_refs > 0).then(|| {
            (
                fixed,
                json!({ "removed_chars": removed_chars, "removed_refs": removed_refs }),
            )
        })
    }
}
```

`html_entity_fixer.rs` のテストの上に:

```rust
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Value, json};

use super::PreParseFilter;
use super::html_entities::lookup;
use super::segments::map_unprotected;

static NAMED_REF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"&([A-Za-z][A-Za-z0-9]*);").unwrap());
const PREDEFINED: [&str; 5] = ["amp", "lt", "gt", "quot", "apos"];

pub struct HtmlEntityFixer;

impl PreParseFilter for HtmlEntityFixer {
    fn name(&self) -> &'static str {
        "HtmlEntityFixer"
    }

    fn apply(&self, xml: &str) -> Option<(String, Value)> {
        // 独自のエンティティを宣言している文書は、宣言済みの名前を壊さないよう対象外にする
        if xml.contains("<!ENTITY") || !NAMED_REF.is_match(xml) {
            return None;
        }
        let mut replaced = 0;
        let mut unknown = 0;
        let fixed = map_unprotected(xml, |text| {
            NAMED_REF
                .replace_all(text, |c: &regex::Captures| {
                    let name = &c[1];
                    if PREDEFINED.contains(&name) {
                        c[0].to_string()
                    } else if let Some(chars) = lookup(name) {
                        replaced += 1;
                        chars.chars().map(|ch| format!("&#x{:X};", ch as u32)).collect()
                    } else {
                        unknown += 1;
                        format!("&amp;{name};")
                    }
                })
                .into_owned()
        });
        (replaced + unknown > 0)
            .then(|| (fixed, json!({ "replaced": replaced, "unknown": unknown })))
    }
}
```

`bare_ampersand_escaper.rs` のテストの上に (Rust の regex は先読みが使えないので、`&` ごとに後ろを調べる):

```rust
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Value, json};

use super::PreParseFilter;
use super::segments::map_unprotected;

static REF_AHEAD: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^&(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#x[0-9A-Fa-f]+);").unwrap());

pub struct BareAmpersandEscaper;

impl PreParseFilter for BareAmpersandEscaper {
    fn name(&self) -> &'static str {
        "BareAmpersandEscaper"
    }

    fn apply(&self, xml: &str) -> Option<(String, Value)> {
        if !xml.contains('&') {
            return None;
        }
        let mut escaped = 0;
        let fixed = map_unprotected(xml, |text| {
            let mut out = String::with_capacity(text.len());
            let mut rest = text;
            while let Some(i) = rest.find('&') {
                out.push_str(&rest[..i]);
                if REF_AHEAD.is_match(&rest[i..]) {
                    out.push('&');
                } else {
                    escaped += 1;
                    out.push_str("&amp;");
                }
                rest = &rest[i + 1..];
            }
            out.push_str(rest);
            out
        });
        (escaped > 0).then(|| (fixed, json!({ "escaped": escaped })))
    }
}
```

`localized_date_fixer.rs` のテストの上に:

```rust
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Value, json};

use super::PreParseFilter;
use super::segments::map_unprotected;

static DATE_ELEMENT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<(pubDate|lastBuildDate|dc:date)>([^<]*)<").unwrap());
static JA_DATE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?s)^([ \t\r\n]*)(?:[日月火水木金土],[ \t\r\n]*)?([0-9]{1,2})[ \t\r\n]+([0-9]{1,2})月[ \t\r\n]+([0-9]{4}(?:[ \t\r\n].*)?)$",
    )
    .unwrap()
});
const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

pub struct LocalizedDateFixer;

impl PreParseFilter for LocalizedDateFixer {
    fn name(&self) -> &'static str {
        "LocalizedDateFixer"
    }

    fn apply(&self, xml: &str) -> Option<(String, Value)> {
        if !xml.contains('月') {
            return None;
        }
        let mut fixed_count = 0;
        let fixed = map_unprotected(xml, |text| {
            DATE_ELEMENT
                .replace_all(text, |c: &regex::Captures| {
                    let Some(d) = JA_DATE.captures(&c[2]) else {
                        return c[0].to_string();
                    };
                    let month: usize = d[3].parse().unwrap_or(0);
                    let Some(name) = month.checked_sub(1).and_then(|i| MONTHS.get(i)) else {
                        return c[0].to_string();
                    };
                    fixed_count += 1;
                    format!("<{}>{}{} {name} {}<", &c[1], &d[1], &d[2], &d[4])
                })
                .into_owned()
        });
        (fixed_count > 0).then(|| (fixed, json!({ "fixed": fixed_count })))
    }
}
```

`mod.rs` の `apply_pre_parse` の並びを置き換える:

```rust
/// Ruby の FeedNormalizer::PRE_PARSE_FILTERS と同じ順番でかける。
pub fn apply_pre_parse(xml: String) -> (String, Vec<String>, Map<String, Value>) {
    let filters: [&dyn PreParseFilter; 5] = [
        &invalid_xml_char_remover::InvalidXmlCharRemover,
        &html_entity_fixer::HtmlEntityFixer,
        &bare_ampersand_escaper::BareAmpersandEscaper,
        &localized_date_fixer::LocalizedDateFixer,
        &atom_namespace_fixer::AtomNamespaceFixer,
    ];
```

(以降のループはそのまま。Rust のフィルタは panic しない実装なので、Ruby の「例外を捕まえて飛ばす」に相当する処理は入れない)

`fetcher/src/parse/date.rs` から `JA_RFC822`、`MONTHS`、`englishize_japanese`、`parse_datetime` の中の `englishized` の行、テスト `parses_japanese_localized_rfc822`、使われなくなった `use regex::Regex;` と `use std::sync::LazyLock;` を消す。`parse_datetime` の該当箇所は次に戻す:

```rust
    let normalized = replace_zone_abbrev(t);
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `cd fetcher && cargo test --lib`
Expected: PASS (golden テストは次の Task で扱う)

- [ ] **Step 5: fmt/clippy を通してコミット**

```bash
cd fetcher && cargo fmt && cargo clippy --all-targets -- -D warnings && cd ..
git add fetcher/src/filters fetcher/src/parse/date.rs
git commit -m "fetcherに壊れたフィードを直すパース前フィルタをRailsと同じ順番で入れる"
```

### Task 13: RelativeUrlResolver をフィードの URL 基準にし、golden を一致させる (Rust)

**Files:**
- Modify: `fetcher/src/filters/relative_url_resolver.rs`
- Modify: `fetcher/tests/golden.rs` (`golden_tests!` に Task 10 のフィクスチャ名を足す)

**Interfaces:**
- Produces: `relative_url_resolver::join_like_addressable(base: &str, url: &str) -> String` (base のパスを RFC 3986 5.2.2 のとおり扱う。`resolve_like_rails` は `Channel.normalize_url` 用にそのまま残し、中で使う)

- [ ] **Step 1: 失敗するテストを書く**

`relative_url_resolver.rs` の `mod tests` に足す:

```rust
    #[test]
    fn resolves_against_feed_url_like_rfc3986() {
        let base = "https://example.com/blog/feed.xml";
        assert_eq!(join_like_addressable(base, "/post/1"), "https://example.com/post/1");
        assert_eq!(join_like_addressable(base, "post/2"), "https://example.com/blog/post/2");
        assert_eq!(join_like_addressable(base, "../post/3"), "https://example.com/post/3");
        assert_eq!(join_like_addressable(base, "?page=2"), "https://example.com/blog/feed.xml?page=2");
        assert_eq!(join_like_addressable(base, "#top"), "https://example.com/blog/feed.xml#top");
        assert_eq!(join_like_addressable(base, "//cdn.example.com/x"), "https://cdn.example.com/x");
    }

    #[test]
    fn surrounding_whitespace_is_ignored() {
        let mut f = feed(Some("https://example.com/"), &["\n  https://example.com/a\n", "\n/b\n"]);
        let details = apply(&mut f, "https://example.com/blog/feed.xml").unwrap();
        assert_eq!(f.entries[0].url.as_deref(), Some("\n  https://example.com/a\n"));
        assert_eq!(f.entries[1].url.as_deref(), Some("https://example.com/b"));
        assert_eq!(details["base_url"], "https://example.com/blog/feed.xml");
    }
```

`fetcher/tests/golden.rs` の `golden_tests!(...)` の末尾に足す:

```rust
    rss_repair_entities,
    rss_localized_dates,
    rss_link_whitespace_and_empty_guid,
    rss_relative_urls_subdir,
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `cd fetcher && cargo test`
Expected: FAIL (新しい単体テストと、作り直した golden の一部)

- [ ] **Step 3: 実装する**

`join_like_addressable` を次に置き換える:

```rust
/// Addressable::URI.join(base, url) を RFC 3986 5.2.2 のとおりに再現する。
/// Addressable と同じく文字のエンコードや大文字小文字の正規化はしない。
pub fn join_like_addressable(base: &str, url: &str) -> String {
    let r = split_uri(url);
    let rest = r.query_and_fragment();
    if let Some(scheme) = r.scheme {
        // Addressable は不正なスキームで InvalidURIError を投げ、Rails ではフィードの取り込み全体が
        // 失敗する。ここでは再現せず、そのまま返す
        if !SCHEME.is_match(scheme) {
            return url.to_string();
        }
        let authority = r.authority.map(|a| format!("//{a}")).unwrap_or_default();
        return format!("{scheme}:{authority}{}{rest}", remove_dot_segments(r.path));
    }
    let b = split_uri(base);
    let scheme = b.scheme.unwrap_or_default();
    if let Some(authority) = r.authority {
        return format!("{scheme}://{authority}{}{rest}", remove_dot_segments(r.path));
    }
    let prefix = match b.authority {
        Some(a) => format!("{scheme}://{a}"),
        None => format!("{scheme}:"),
    };
    if r.path.is_empty() {
        let mut out = format!("{prefix}{}", b.path);
        if let Some(q) = r.query.or(b.query) {
            out.push('?');
            out.push_str(q);
        }
        if let Some(f) = r.fragment {
            out.push('#');
            out.push_str(f);
        }
        return out;
    }
    let path = if r.path.starts_with('/') {
        remove_dot_segments(r.path)
    } else if b.authority.is_some() && b.path.is_empty() {
        remove_dot_segments(&format!("/{}", r.path))
    } else {
        let dir = b.path.rfind('/').map_or("", |i| &b.path[..=i]);
        remove_dot_segments(&format!("{dir}{}", r.path))
    };
    format!("{prefix}{path}{rest}")
}
```

`has_relative_url` を、前後の空白を除いて判定するように置き換える:

```rust
fn has_relative_url(url: Option<&str>) -> bool {
    match url.map(ruby_strip) {
        None => false,
        Some(u) if u.is_empty() => false,
        Some(u) => !(u.starts_with("http://") || u.starts_with("https://")),
    }
}
```

(`use crate::ruby::is_blank;` を `use crate::ruby::{is_blank, ruby_strip};` に変える。`is_blank` が使われなくなったら import から外す)

`apply` の中の `resolve_like_rails(&from, feed_url)` (2箇所) を `join_like_addressable(feed_url, ruby_strip(&from))` に、`"base_url": base_url(feed_url)` を `"base_url": feed_url` に変える。モジュール先頭のドキュメントコメントを「フィードの URL を基準に RFC 3986 のとおり解決する (Channel.normalize_url 用の resolve_like_rails は scheme://host 基準のまま)」に直す。

既存のテスト `resolves_against_scheme_and_host_only` など、RelativeUrlResolver の基準が `scheme://host` であることを前提にしたものは、Rails の Task 7 と同じ期待値に直す。

- [ ] **Step 4: テストと golden が通ることを確かめる**

Run:
```bash
cd fetcher && cargo test && cargo build --release
./target/release/fetcher golden-check testdata/corpus
```
Expected: すべて PASS。コーパスは Task 10 Step 3 で作り直した golden と全件一致 (`N / N matched`)。一致しないものは、原因を最小の合成フィクスチャにして `testdata/fixtures/` に足し、Rails で golden を作ってから Rust を直す

- [ ] **Step 5: fmt/clippy を通してコミットし、PR を作る**

```bash
cd fetcher && cargo fmt && cargo clippy --all-targets -- -D warnings && cd ..
git add fetcher/src/filters/relative_url_resolver.rs fetcher/tests/golden.rs
git commit -m "fetcherのRelativeUrlResolverをフィードのURL基準にし、フィルタ入りのRailsのgoldenと一致させる"
git push -u origin feat/fetcher-repair-filters
```

### Task 14: 影モードで確かめる

**Files:** なし (手元の `tmp/shadow-runs/` のみ)

- [ ] **Step 1: 定期実行のバイナリを差し替える**

```bash
cp fetcher/target/release/fetcher tmp/shadow-runs/fetcher.new && mv -f tmp/shadow-runs/fetcher.new tmp/shadow-runs/fetcher
```

- [ ] **Step 2: 差し替え後の最初の2回分のレポートを集計する**

```bash
cd tmp/shadow-runs
for f in $(ls -t reports/*.jsonl | head -2); do
  jq -s -c '{channels:length, status:(group_by(.status)|map({(.[0].status):length})|add), guid_mismatch:(map(select(.existing_flagged != .entries_compared))|length), new:(map(.new_guids|length)|add)}' "$f"
  ./check_new_guids.sh "$f" | jq -c 'select(.new != .saved)'
done
```

Expected: guid のずれが 0。Rails が保存していない新規判定は、これまでに原因が分かっているもの (取得元で結果が変わる検索フィード、更新の速いフィード、Rails のジョブの遅れ) だけ
