# フィード新着チェックの外部ワーカー化 設計書

- 作成日: 2026-09-25
- ステータス: 設計レビュー待ち

## 1. 背景と目的

Production (Heroku) のランニングコストは月約 $117 で、内訳は web / worker の Standard-2X dyno が各 $50、Heroku Postgres essential-1 が $9、Papertrail が $8。
worker dyno の仕事の大半はフィードの新着チェック (`ChannelItemsUpdaterJob`、1日約15,000件) で、2026-09 時点の実測では次のとおり。

- worker dyno: RSS 平均 約640MB / 最大 約800MB、CPU load はほぼ 0
- `ChannelItemsUpdaterJob`: 1日 15,450件、enqueue から完了まで平均 176秒 (待ち行列が発生している)
- 対象チャンネル: 2,192件、フィードのホストは 1,052種類。多いのは www.youtube.com (268チャンネル)、note.com (231)、anchor.fm (182)

この仕事を Rails から切り離し、**自分で管理している複数のマシン**(自宅のマシンなど)で動く Rust 製ワーカーに任せる。
あわせて残りの軽いジョブを Puma 内の Solid Queue に寄せ、worker dyno を廃止する。

### 優先順位

1. ランニングコストを下げる
2. 技術的に楽しみながらやる

### ゴール

- worker dyno を廃止し、月額を約 $72 にする ($117 − worker dyno $50 + Workers Paid $5)
- フィードの新着チェックを、台数を自由に増減できるワーカー群で処理する
- 既存の Postgres のスキーマとデータを尊重する (変更は追加のみ)
- 取り込み結果を現行の Rails 実装と同等にする

### やらないこと (このサブプロジェクトの範囲外)

- web (Rails) のホスティング先の移行や、Cloudflare 上でのフロントエンド作り直し
- Postgres のホスティング先の移行
- 通知系ジョブ (メール・webhook の定期配信) の移行
- 手動取得 (`Channels::FetchController`、`mode: :only_recent`) と、チャンネル登録時のプレビューの移行。どちらもユーザー操作起点で件数が少ないので、Rails に残す
- `RelativeUrlResolver` の解決基準のクセの修正と、`update_info` の OGP 取得頻度の削減。移行を終えてから別途行う

## 2. 全体構成

方針は「判断は中央、手足は各マシン」。ワーカーは DB を知らず、取ってきて整形して返すことだけをする。

```
[自分で管理するマシン群: fetcher (Rust)]
        │ HTTPS + マシンごとのトークン
        ▼
[dispatcher (Cloudflare Workers)] ──Hyperdrive──▶ [Postgres (既存)] ◀── [Rails]
        │
        └──▶ Discord webhook (新着通知・チャンネル変更通知)
```

| コンポーネント | 置き場所 | 技術 | 責務 |
|---|---|---|---|
| fetcher | リポジトリの `fetcher/` | Rust (tokio, reqwest, feed-rs) | 取得・正規化・パース・整形、OGP取得 |
| dispatcher | リポジトリの `dispatcher/` | TypeScript, Hono, postgres.js, Cloudflare Workers + Hyperdrive | 貸し出し、検証、DB書き込み、スケジュール再計算、通知 |
| Rails | 既存 | - | 段階移行のゲート、手動取得・登録時プレビュー、その他のジョブ |

## 3. データモデル (追加のみ)

### `channel_leases` (新規)

```sql
CREATE TABLE channel_leases (
  channel_id   bigint PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
  host         varchar NOT NULL,     -- feed_url のホスト (マシン横断の同一ホスト排他に使う)
  worker_name  varchar NOT NULL,
  leased_until timestamp NOT NULL,
  created_at   timestamp NOT NULL
);
CREATE INDEX index_channel_leases_on_host ON channel_leases (host);
```

マイグレーションは Rails 側 (`db/migrate`) で作り、`db/schema.rb` を唯一のスキーマ定義として保つ。
期限切れの lease は、貸し出し時に同じトランザクションの中で削除する。

既存テーブルへの変更はない。`items.data` は次の節の方針で新規分の中身が軽くなるが、カラムは変えない。

## 4. dispatcher API

認証は `Authorization: Bearer <token>`。トークンはマシンごとに発行し、dispatcher の secret に「ワーカー名 → トークンの SHA-256」の対応表として置く。
トークンからワーカー名を特定して、ログと `channel_leases.worker_name` に残す。

### `POST /leases`

リクエスト: `{ "max": 8 }`

処理 (1トランザクション):

1. 期限切れの `channel_leases` を削除する
2. 次の条件をすべて満たすチャンネルを選ぶ
   - 停止されていない (`channel_stoppers` に無い)
   - チェックが必要 (現行の `needs_check_now` と同じ条件。つまり `last_items_checked_at` が NULL か、`check_interval_hours` − 10分 を過ぎている、または固定スケジュールで今の時間帯に当たっている)
   - lease されていない
   - ホストが、有効な lease のどれとも重複しない
   - `channel_id % 100 < ROLLOUT_PERCENT` (段階移行用。dispatcher の環境変数)
3. `by_check_priority` の順 (`check_interval_hours`, `last_items_checked_at`) に並べ、同じバッチ内ではホストを重複させずに `max` 件まで取る。`FOR UPDATE SKIP LOCKED` を使う
4. `channel_leases` に `leased_until = now() + 10分` で登録する

時刻の扱い: 固定スケジュールの「今の時間帯」は現行 Rails と同じタイムゾーン (`config.time_zone`) で判定する。

レスポンス:

```json
{
  "leases": [
    {
      "lease_id": "123",
      "channel_id": 123,
      "feed_url": "https://example.com/feed.xml",
      "site_url": "https://example.com/",
      "use_proxy": false
    }
  ]
}
```

`lease_id` は `channel_id` と同じ値にする (lease は channel につき1つなので)。`use_proxy` は `proxy_required_domains` にホストが載っているかどうか。

### `GET /shadow/channels?max=N` (影モード用)

チェック対象になるチャンネルを最大 N 件返す。レスポンスの形は `POST /leases` と同じ。lease の登録も含め、DB には一切書き込まない。`ROLLOUT_PERCENT` の条件は適用しない。
影モードの fetcher は、このエンドポイントと `new-guids` だけを使う。

### `POST /channels/:channel_id/new-guids`

リクエスト: `{ "guids": ["...", "..."] }`
レスポンス: `{ "new_guids": ["..."] }`

現行の `only_non_existing` と同じく、`items.guid` が entry の guid とも url とも一致しないものを返す。
fetcher はここで返ってきた entry にだけ OGP 画像を取りに行く。読み取りだけのエンドポイントなので lease は要らず、影モードでも使える。

### `POST /leases/:id/result`

リクエスト:

```json
{
  "fetched": true,
  "error": null,
  "final_url": "https://example.com/feed.xml",
  "proxy_used": false,
  "register_proxy_domain": false,
  "channel": {
    "format": "rss",
    "title": "...",
    "description": "...",
    "site_url": "...",
    "image_url": "...",
    "applied_filters": ["RelativeUrlResolver"],
    "filter_details": { "RelativeUrlResolver": {} }
  },
  "entries": [
    {
      "guid": "...",
      "title": "...",
      "url": "...",
      "image_url": "...",
      "published_at": "2026-09-25T00:00:00Z",
      "data": {
        "entry_id": "...", "title": "...", "url": "...", "published": "...",
        "summary": "...", "itunes_subtitle": "...",
        "enclosure_url": "...", "enclosure_type": "audio/mpeg"
      }
    }
  ],
  "latest_guids": ["...", "..."]
}
```

- `entries` は現行と同じく、新しいものだけを `published` の昇順で送る。`channel` が null のときはチャンネル情報を更新しない
- `latest_guids` は、フィード内で公開日時が新しい2件の entry_id と url。新着通知の判定に使う
- 取得に失敗したときは `fetched: false` にして、`error` に `{ "kind": "http_status" | "timeout" | "parse" | ..., "message": "..." }` を入れる

処理:

1. **リダイレクト**: `final_url` が現在の `feed_url` と違えば `feed_url` を更新する。行き先の URL が別チャンネルとして既に登録されていたら、`channel_stoppers` に理由付きで登録し、以降の item の保存をしない (現行の `fetch_and_save_items` と同じ)
2. **チャンネル情報の更新**: 現行の `update_info` / `save_from` に相当する処理。strip、空文字の nil 化、バリデーションは節6に従う。重要なフィールドが変わったときは Discord の content_updates に差分を投稿する。`last_items_checked_at`、`filter_details`、`updated_at`、`created_at` の変化は無視する (現行の `notify_channel_change` と同じ)
3. **item の保存**: `(channel_id, guid)` で upsert し、節6の検証に通らない entry は飛ばして Sentry に warning を送る
4. **新着通知**: 新規に insert された item のうち、guid が `latest_guids` に含まれるものを Discord に投稿する (現行の `ItemCreationNotifierJob` と同じ判定)。投稿は `ctx.waitUntil` で行い、失敗してもレスポンスには影響させない。現行 `DiscoPosterJob` の `sleep 1` に相当する間隔を空ける
5. **proxy**: `register_proxy_domain` が true なら `proxy_required_domains` にホストを登録する
6. **チェック済みの記録**: `last_items_checked_at = now()` にする。取得に失敗した場合も進める (現行と同じ)
7. **再計算**: `check_interval_hours` と固定スケジュール (`channel_fixed_schedules`) を計算し直す。ロジックは現行の `set_check_interval!` / `adjust_schedules!` / `analyze_publishing_patterns` をそのまま移す
8. lease を削除する

1〜3、6〜8 は1トランザクションで行う。

## 5. fetcher (Rust)

### 実行形態

- 単一バイナリ。設定は環境変数か設定ファイルで、`API_URL`、`TOKEN`、`WORKER_NAME`、`CONCURRENCY` (既定 8)、`FEED_PROXY_URL` / `FEED_PROXY_SECRET` (任意)
- Linux は systemd、macOS は launchd で常駐させる。サンプルの unit ファイルと plist を同梱する
- `--dry-run` モード: `GET /shadow/channels` でチャンネルを受け取り、取得・整形までを行う。`result` は送らずに、比較用の JSON を出力する (影モード用、節8)

### 並列と礼儀

- 同時に処理するチャンネルは `CONCURRENCY` 件まで。空いた枠の分だけ `POST /leases` で先に借りておく
- ホストごとの門番: 同じホストへは同時に1本まで、前回のアクセスから最低1秒空ける。フィードと OGP の両方の取得に適用する
- マシンをまたいだ同一ホストの排他は、dispatcher 側の lease が担う
- lease の期限 (10分) を超えそうな処理は打ち切って、エラーとして result を送る
- HTTP のタイムアウト: 接続 10秒、全体 30秒。User-Agent は、現行 Rails が送っている Faraday の既定値 (`Faraday v2.14.3`) と同じ文字列を既定にし、設定で変えられるようにする。取得できるかどうかが UA に左右されるフィードがあり得るため、移行中は揃えておく

### 処理パイプライン (現行と同等にする)

1. **取得**: リダイレクトを追い、最終 URL を記録する。Cookie を保持する (現行の cookie_jar と同じ)
2. **proxy**: `use_proxy` なら最初から proxy を通す。直接取得で接続失敗・タイムアウト・403 だったときは proxy で再試行し、成功したら `register_proxy_domain: true` にする (現行の `Httpc` と同じ)。proxy の設定が無いマシンでは再試行しない
3. **文字コード**: UTF-8 として解釈し、不正なバイトは取り除く
4. **パース前フィルタ** (trait `PreParseFilter`): `HtmlEntityFixer`、`AtomNamespaceFixer`
5. **パース**: feed-rs を使う。Feedjira の判別 (RSS / Atom / ITunesRSS / AtomYoutube / AtomGoogleAlerts) に相当する `format` を決める
6. **パース後フィルタ** (trait `PostParseFilter`): `RelativeUrlResolver`。`scheme://host` を基準に解決する現行のクセも再現する
7. **チャンネル情報**: `build_from_*` と同じ規則で title / description / site_url / image_url を作る。RSS / Atom / YouTube では site_url の OGP を取る (現行と同じ)
8. **entry の整形**:
   - url: entry の url → enclosure_url → site_url の順で最初にあるもの。strip してから、マルチバイト文字と `"` をパーセントエンコードする
   - guid: entry_id → url。どちらも無ければ飛ばす
   - image_url: itunes_image → image → YouTube の場合はサムネイル URL → OGP 画像 (新しい guid のみ)。http(s) の URL として不正なら null
   - `data`: 節4 の8つのキーだけを入れる

フィルタ名は Ruby のクラス名 (demodulize 後) と同じ文字列にして、`applied_filters` の意味を保つ。
feed-rs ではフィルタ無しでもパースできるケースがあっても、フィルタは残す。適用有無が「問題のあるフィード」の目印になっているため。

## 6. dispatcher での検証 (門番)

ActiveRecord を通らずに書き込むので、現行のモデルのコールバックとバリデーションを dispatcher で再実装する。fetcher の出力は信用しない。

**Item**
- title は strip し、空なら `〓`。256文字まで
- guid は必須で、2083文字まで
- url は必須で、http(s) の URL 形式、4096文字まで
- image_url は strip し、空文字なら null。http(s) の URL 形式で 4096文字まで
- published_at は必須。無い entry は飛ばす (現行と同じ)

**Channel**
- title は strip して必須、256文字まで
- description は strip して 1400文字まで。空文字なら null
- site_url / image_url は空文字なら null。http(s) の URL 形式で 4096文字まで

URL 形式の判定は Ruby の `URI.regexp(%w[http https])` と同じものを受け入れるようにする。境界ケースはテストで固定する。

## 7. Rails 側の変更

- `ROLLOUT_PERCENT` (環境変数) を Rails にも設定する。`Channel.fetch_and_save_items` は `channel_id % 100 >= ROLLOUT_PERCENT` のチャンネルだけに `ChannelItemsUpdaterJob` を積む
- `Channel` の `after_create_commit` も同じ条件にする。対象外になった新規チャンネルは `last_items_checked_at` が NULL なので、次の貸し出しで拾われる
- dispatcher が書いた item には `after_create_commit` が走らないので、`ItemCreationNotifierJob` の通知は dispatcher が代わりに行う。Rails で作られた item (Rails 側に残る割合と手動取得の分) では今のまま Rails が通知する
- 100% になったら `SOLID_QUEUE_IN_PUMA=1` を設定して worker dyno を 0 にする。Puma の中の Solid Queue で、通知系・雑用・手動取得のジョブを処理する。そのあと web dyno のメモリの推移を確認する
- `ProxyRequiredDomainsRecheckerJob` は Rails に残す

`ROLLOUT_PERCENT` は Rails と dispatcher の両方に同じ値を設定する。値がずれている間に取りこぼしや二重取得が起きても、guid の一意制約と `needs_check_now` の条件によって、結果は冪等になる。

## 8. 移行手順

1. **影モード**: 本番の DB を使って fetcher を `--dry-run` で回す。Rust の出力と、既存の item (Rails が保存したもの) を突き合わせるスクリプトで、一致率と差分の傾向を確認する。この段階の fetcher は `GET /shadow/channels` と `new-guids` だけを使うので、DB への書き込みは一切起きない。本番の取り込みは Rails が今までどおり行う
2. **割合移行**: `ROLLOUT_PERCENT` を 10 → 50 → 100 と上げる。各段階で Sentry、取り込み件数、`last_items_checked_at` の遅れ具合を確認する
3. **切り替え完了**: 節7 の手順で worker dyno を廃止する
4. **巻き戻し**: `ROLLOUT_PERCENT=0` にして、worker dyno を 1 に戻せば元の状態に戻る

## 9. テスト

- **fetcher の単体テスト**: 各フィルタ (`test/services/feed_filters/` の Ruby テストを移植)、URL の整形、guid と image_url のフォールバック
- **正解との比較テスト**: 本番から種類の違うフィードを30件程度選び、フィクスチャにする (RSS / Atom / Podcast / YouTube / Google Alerts / 現在フィルタが適用されている10チャンネルを必ず含める)。同じ入力を Rails (Feedjira + `FeedNormalizer` + モデルの整形) に通した結果を rake タスクで JSON に書き出して、それを正解として Rust の出力と比べる
- **dispatcher のテスト**: vitest と手元の docker compose の Postgres を使う。確かめる内容は次のとおり
  - 貸し出しの条件 (チェック間隔、固定スケジュール、停止中、ホストの排他、ロールアウトの割合)
  - lease の期限切れ
  - 同時に貸し出しを受けたときに重複しないこと
  - 検証と upsert
  - リダイレクトと停止
  - 間隔とスケジュールの再計算 (Rails のテストと同じ入力で同じ結果になること)
  - 通知の判定
- **本番の影モード** (節8)

## 10. 運用・監視

- dispatcher: `wrangler.toml` で `[observability] enabled = true` にして Workers Logs を使う。例外は Sentry に送る
- fetcher: 構造化ログを標準出力に出す (systemd journal / launchd のログに出る)。例外は Sentry (`sentry` crate) に送る。ワーカー名をタグに付ける
- 遅れの監視: `needs_check_now` に当たるのに1時間以上チェックされていないチャンネルの数を、既存の DAU 通知と同じ要領で Discord に定期投稿する (Rails の recurring job として追加)
- Hyperdrive の接続先: Heroku Postgres の認証情報が変わったら、Hyperdrive の設定を更新する。手順を README に書く

## 11. コスト

| 項目 | 変化 |
|---|---|
| worker dyno (Standard-2X) | −$50 |
| Cloudflare Workers Paid (Hyperdrive のクエリ数無制限のため) | +$5 |
| 合計 | 約 $117 → 約 $72 / 月 |

Hyperdrive は Workers Free プランでも使えるが、1日10万クエリの上限がある。想定では1日7.5万〜15万クエリになるため、Paid プランを前提にする。

## 12. 将来の拡張 (今回はやらない)

- ワーカーからの heartbeat による lease 延長と、期限の短縮
- 条件付き GET (ETag / Last-Modified) で帯域とパースの手間を減らす
- `update_info` の OGP 取得頻度を下げる
- `RelativeUrlResolver` の解決基準をフィードのディレクトリに直す
- 手動取得とチャンネル登録のプレビューも fetcher 経由にする
- `items.data` の既存データの軽量化 (TOAST 約1.6GB)
