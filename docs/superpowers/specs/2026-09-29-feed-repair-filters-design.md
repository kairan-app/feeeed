# 壊れたフィードを直すフィルタ (計画2a) 設計書

- 作成日: 2026-09-29
- ステータス: 設計レビュー待ち
- 親の設計書: `docs/superpowers/specs/2026-09-25-feed-fetcher-offload-design.md`

## 1. 背景

フィードの新着チェックを Rust の fetcher に移す計画 (親の設計書) の影モードで、Rails と Rust の結果を本番のフィードで突き合わせた。
guid の判定は約21万件ですべて一致した。いっぽうで、Rails の取り込みそのものが次のようなフィードで正しく動いていないことが分かった。

- 本文や属性に `&nbsp;` などの HTML のエンティティ、`;` の無い素の `&` (`?a=1&b=2`)、XML で使えない制御文字 (`\x08` など) があると、libxml2 がそこで読むのをやめる。Rails はそこから後ろの entry を黙って捨てている (50件中25件だけ保存、など)
- `<link>` の中身が改行で始まっていると、`RelativeUrlResolver` が相対 URL とみなして解決しようとし、取り込みに失敗する
- 空の `<guid/>` は、Feedjira (sax-machine) で entry_id が `:no_buffer` というシンボルになり、そのまま guid として保存される。同じチャンネルの item がすべて同じ guid になる
- 日本から取得すると、Bing の検索フィードは `金, 25 9月 2026 16:07:00 GMT` のような日時を返す。Ruby の `DateTime.parse` は 10〜12月を読み違え (`1 10月` → 9月10日)、1月は読めない
- `RelativeUrlResolver` は `scheme://host` を基準に相対 URL を解決していて、フィードの URL を基準にしていない

親の設計書では「取り込み結果を現行の Rails 実装と同等にする」をゴールにしていた。これを改め、**Rails と Rust の両方を「あるべき姿」に揃える**。

### 計画2の分け方

親の設計書の計画2 (切り替え) を次の2つに分ける。この設計書は 2a を扱う。

- **2a (この設計書)**: 壊れたフィードを直すフィルタと整形ルールを、Rails と Rust の両方に入れる。今の本番の Rails にもすぐ効く
- **2b**: 書き込みの経路 (lease / result)、段階移行、worker dyno の廃止。2a で Rails と Rust の挙動が揃ってから設計する

2b に向けて、次のことは決めてある。

- 本番の fetcher は自宅の常時稼働機で動かす
- fetcher が止まったときは、遅れを Discord に通知して手で対応する (Rails が自動で代わりに取ることはしない)

## 2. 方針

- パーサは厳密なままにして、壊れたフィードは「直すフィルタ」を通してから読む。これまでの `HtmlEntityFixer` / `AtomNamespaceFixer` と同じ考え方
- フィルタは XML を**文字列のまま走査して**直す。DOM に読み込んで書き出し直す方式 (今の `HtmlEntityFixer`) は、libxml2 が壊れた XML を勝手に直す挙動に結果が左右され、Rust で再現できないため
- CDATA セクション (`<![CDATA[ ... ]]>`) とコメント (`<!-- ... -->`) の中は、フィルタ 1 以外では書き換えない。CDATA の中の `&` は文字そのものなので、エスケープすると内容が変わってしまう
- どのフィルタを適用したかは、これまでどおり `channels.applied_filters` と `filter_details` に残す。壊れたフィードの目印になる
- **guid の決め方は変えない**。guid は `entry_id` → `url` の順で、既存の item との重複判定の鍵になっているため、変わると同じ記事が二重に保存される。例外は空の `<guid/>` (節4)

## 3. パース前フィルタ

`FeedNormalizer::PRE_PARSE_FILTERS` を次の順にする。

| 順 | フィルタ | 種別 | 直すもの |
|---|---|---|---|
| 1 | `InvalidXmlCharRemover` | 新規 | XML 1.0 で使えない文字 (タブ・LF・CR 以外の U+0000〜U+001F、U+FFFE、U+FFFF) を取り除く。これらを指す文字参照 (`&#8;`、`&#x1F;` など) も取り除く。CDATA とコメントの中も対象にする (libxml2 はそこでも止まるため) |
| 2 | `HtmlEntityFixer` | 拡張 | 文書全体の名前付きエンティティ `&name;` を直す。XML の定義済み (`amp` `lt` `gt` `quot` `apos`) はそのまま。HTML のエンティティ表にある名前は数値の文字参照 (`&nbsp;` → `&#xA0;`) に置き換える。表に無い名前は `&amp;name;` にして文字として残す |
| 3 | `BareAmpersandEscaper` | 新規 | 文字参照の形 (`&name;`、`&#123;`、`&#x1F;`) になっていない `&` を `&amp;` にする |
| 4 | `LocalizedDateFixer` | 新規 | `<pubDate>` `<lastBuildDate>` `<dc:date>` の中身が「`[日月火水木金土], D M月 YYYY ...`」の形なら、曜日を取り除き、月を英語の略称にする (`金, 25 9月 2026 16:07:00 GMT` → `25 Sep 2026 16:07:00 GMT`) |
| 5 | `AtomNamespaceFixer` | 今のまま | - |

- 2〜4 は、CDATA とコメントの外 (要素の本文と属性の値) だけを書き換える
- `HtmlEntityFixer` は名前を変えずに対象を文書全体に広げる。これまでの対象 (channel の copyright と generator) は新しい処理に含まれる
- HTML のエンティティ表は、WHATWG の named character references のうち `;` で終わる名前 (約2,200件) を JSON にしたものを、リポジトリに1つだけ置く (`app/services/feed_filters/data/html_entities.json`)。Ruby と Rust の両方がこのファイルを読む
- 各フィルタは、直すものがあったときだけ `mark_as_applied!` する。`details` には直した件数を入れる (例: `{ replaced: 3 }`)
- フィルタ自体が例外を出したら、そのフィルタを飛ばし、元の文字列のまま次のフィルタに進む。例外は Sentry に送る。フィルタのバグで取り込み全体を止めないため

## 4. 整形のルール

Rails (`Channel.fetch_and_save_items`、`RelativeUrlResolver`) と Rust (`fetcher/src/shape/`) の両方で次のように変える。

- **`<link>` の前後の空白**: `RelativeUrlResolver` は、前後の空白・改行を取り除いた値で相対 URL かどうかを判定し、取り除いた値を解決する。絶対 URL だった場合は url を書き換えない (guid が url を兼ねているフィードで guid を変えないため。保存する url の strip は今までどおり `Channel.fetch_and_save_items` が行う)
- **空要素の値**: Ruby では RSS の `<guid/>` と `<guid></guid>` が `:no_buffer` になる。Atom の `<id/>` は nil で問題ない
- **空の `<guid/>`**: entry_id が空 (Ruby では `:no_buffer`、または空文字) のときは entry_id が無いものとして扱い、url にフォールバックする。既存の item の guid は `no_buffer` になっているので、該当するチャンネルでは直した直後に過去の記事が一度だけ新着として入る。これは受け入れる (今は同じ guid で上書きし続けていて、壊れているため)
- **相対 URL の解決基準**: `RelativeUrlResolver` の基準を `scheme://host` からフィードの URL (リダイレクト後) に変え、RFC 3986 の通りに解決する
  - guid が url を兼ねているチャンネルで、基準の変更によって url が変わると、既存の記事が二重に保存される。2026-09-28 時点で `RelativeUrlResolver` が適用されているチャンネルは8件、うち guid が url を兼ねているものは3件で、3件ともフィードがドメイン直下にあるため結果は変わらない (確認済み)
- **`applied_filters` の変化は通知しない**: `Channel#notify_channel_change` の無視するフィールドに `applied_filters` を足す。新しいフィルタが最初に適用されるとき、チャンネルごとに Discord の content_updates へ通知が飛ぶのを防ぐ

## 5. 今のまま残すもの

- フィルタでも直せない壊れ方 (値の無い属性、重複した属性、閉じていないタグなど) では、今までどおり libxml2 がそこで読むのをやめる。Rust もこの挙動を Rails に合わせたままにする
- Rust の日時パーサにある日本語の日時の特別扱い (`englishize_japanese`) は、`LocalizedDateFixer` に置き換えて消す

## 6. 進める順番

1. **Rails**: 節3・節4 を1本の PR にして本番にデプロイする。翌日まで次を見る
   - Sentry の新しいエラー
   - 1日の item の保存件数 (増えるのは想定どおり。途中で捨てていた entry を拾えるようになるため)
   - 新しいフィルタが `applied_filters` に付いたチャンネルの数
2. **Rust**: 同じフィルタと整形ルールを移植する。golden の期待値をフィルタ入りの Rails で作り直し、Rust を一致させる。`sax.rs` のパースを止める挙動 (節5) は残す
3. **影モード**: 定期実行のバイナリを差し替え、これまで Rails と差が出ていたフィードで差が消えることを確かめる

## 7. テスト

**Rails** (`test/services/feed_filters/pre_parse/`、`test/services/feed_normalizer_test.rb`)

- フィルタごとの単体テスト
  - 直すべき箇所を直すこと (要素の本文と属性の値の両方)
  - CDATA とコメントの中を書き換えないこと (フィルタ 1 は除く)
  - 直すものが無い XML は素通りし、`applied` にならないこと
  - `HtmlEntityFixer`: XML の定義済みエンティティと数値の文字参照はそのまま。表に無い名前は `&amp;name;` になること
  - `LocalizedDateFixer`: 1〜12月、曜日の有無、英語の日時に手を入れないこと
- `FeedNormalizer` を通した結合テスト: 途中で切れていた合成フィクスチャで、すべての entry が取れること
- `Channel.fetch_and_save_items`: 改行入りの `<link>`、空の `<guid/>`、`applied_filters` だけが変わったときに通知が飛ばないこと

**Rust** (`fetcher/`)

- 同じ内容の単体テスト
- golden: 影モードで見つかった形 (未定義のエンティティ、素の `&`、制御文字、日本語の日時、改行入りの `<link>`、空の `<guid/>`、`/` で始まらない相対 URL) を合成フィクスチャにし、フィルタ入りの Rails で期待値を作る
- エンティティ表を Ruby と Rust が同じファイルから読んでいること (Rust は `include_str!` でリポジトリの JSON を埋め込む)

## 8. やらないこと

- 本文サイズの上限、`items.data` の形、dispatcher 呼び出しの再試行 (2b で扱う)
- 値の無い属性や閉じていないタグを直すフィルタ (本番でまだ見つかっていない)
- 既存の item (guid が `no_buffer` のものなど) の掃除
