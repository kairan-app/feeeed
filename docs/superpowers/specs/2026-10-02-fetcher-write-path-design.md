# fetcher の書き込み経路と worker dyno の廃止 (計画2b) 設計書

- 作成日: 2026-10-02
- ステータス: 設計レビュー待ち
- 親の設計書: `docs/superpowers/specs/2026-09-25-feed-fetcher-offload-design.md`
- 前段: `docs/superpowers/specs/2026-09-29-feed-repair-filters-design.md` (計画2a)

## 1. 背景と目的

計画1 (影モード) と計画2a (壊れたフィードを直すフィルタ) で、Rust の fetcher が Rails と同じ結果を出せることを確かめた。
この設計書は、fetcher の結果を本番の DB に書き込む経路を作り、段階的に切り替えて worker dyno を廃止するところまでを扱う。

### 親の設計書からの大きな変更: 書き込みは Rails が行う

親の設計書では、Cloudflare Workers の dispatcher (TypeScript) が貸し出し・検証・保存・通知・チェック間隔の再計算をすべて行う予定だった。
これをやめ、**貸し出しと保存は Rails の API が行う**。dispatcher は影モードのためだけに残し、切り替えが済んだら廃止する。

理由:

- 手動取得とチャンネル登録時のプレビューは Rails に残るので、保存まわりの Ruby のコード (`save_from`、`fetch_and_save_items`、`set_check_interval!` など) は消せない。dispatcher に移すと、同じロジックを Ruby と TypeScript の二重に持つことになる
- 計画2a で、同じ挙動を2か所で揃えるのは手間がかかると分かった。二重実装はパースと整形 (Rust) だけに留め、保存の門番は ActiveRecord のバリデーションとコールバックにそのまま任せる
- 貸し出しの条件も、既存のスコープ (`not_stopped`、`needs_check_now`、`by_check_priority`) を使える
- Workers Paid ($5/月) が要らなくなる。Hyperdrive が使っていた Heroku Postgres の接続 (最大5本) も空く

引き換えに、書き込みの負荷と可用性は web dyno に寄る。1日約1.5万回の結果の受け取りは平均で6秒に1回程度で、重いパース (Feedjira / Nokogiri) と外部への取得は fetcher 側に残るため、web dyno で受け止められる見込み。web dyno が落ちているときはサイト自体が落ちているので、fetcher だけが動けても意味は薄い。

### 決まっていること (計画2a の設計書より)

- 本番の fetcher は自宅の常時稼働の Linux マシンで動かす
- fetcher が止まったときは、遅れを Discord に通知して手で対応する。Rails が自動で代わりに取得することはしない

### ゴール

- 新着チェック (`ChannelItemsUpdaterJob` の定期分) をすべて fetcher に移し、worker dyno を廃止する
- 取り込み結果・通知・チェック間隔の再計算が、今の Rails と変わらないこと
- 月額を約 $117 から約 $67 にする

### やらないこと

- 新しいチャンネルの初回取得 (`after_create_commit` の `mode: :all`)、手動取得、登録時のプレビューの移行。Rails に残す
- dispatcher (Cloudflare) を本番の書き込みに使うこと
- 条件付き GET、`update_info` の OGP 取得頻度の削減など、親の設計書の「将来の拡張」に挙げたもの

## 2. 全体構成

```
[自宅の Linux マシン: fetcher (Rust, systemd で常駐)]
        │ HTTPS + マシンごとのトークン
        ▼
[Rails (web dyno) の /fetcher/* API] ──▶ Postgres (既存)
        └─▶ 保存後の通知などのジョブは Solid Queue へ (切り替え後は Puma 内で処理)
```

| コンポーネント | 責務 |
|---|---|
| fetcher (`fetcher/`) | 貸し出しを受ける、取得・フィルタ・パース・整形、新しい guid の照会、OGP の取得、結果の送信 |
| Rails | 貸し出し、結果の保存 (バリデーション・チャンネル情報・item・リダイレクトと停止)、通知、チェック間隔と固定スケジュールの再計算、遅れの監視、段階移行のゲート |
| dispatcher (`dispatcher/`) | 影モード専用。切り替え後に廃止する |

## 3. データモデル

### `channel_leases` (新規)

```sql
CREATE TABLE channel_leases (
  channel_id   bigint PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
  host         varchar NOT NULL,     -- feed_url のホスト (同じホストの排他に使う)
  worker_name  varchar NOT NULL,
  leased_until timestamp NOT NULL,
  created_at   timestamp NOT NULL
);
CREATE INDEX index_channel_leases_on_host ON channel_leases (host);
```

マイグレーションは `db/migrate` で作る。既存のテーブルは変えない。

## 4. API (Rails)

コントローラは `Fetcher::` 名前空間に置き、パスは `/fetcher/*` にする。CSRF の検査とセッションは使わない。

### 認証

`Authorization: Bearer <token>`。トークンはマシンごとに発行し、環境変数 `FETCHER_TOKENS` に「ワーカー名 → トークンの SHA-256 (16進)」の JSON として置く (今の dispatcher と同じ方式)。
照合は定数時間で行う。トークンから分かったワーカー名を、ログと `channel_leases.worker_name` に残す。

### `POST /fetcher/leases`

リクエスト: `{ "max": 8 }` (1〜32)

1つのトランザクションで次を行う。

1. 期限切れの `channel_leases` を削除する
2. 次の条件をすべて満たすチャンネルを、`by_check_priority` の順に選ぶ。行は `FOR UPDATE SKIP LOCKED` で取る
   - `not_stopped` かつ `needs_check_now`
   - lease されていない
   - `feed_url` のホストが、有効な lease のどれとも同じでない
   - `channel_id % 100 < ROLLOUT_PERCENT`
3. 同じバッチの中でホストが重ならないように、`max` 件まで取る
4. `channel_leases` に `leased_until = 今 + 10分` で登録する

レスポンス (影モードの `GET /shadow/channels` と同じ形):

```json
{
  "leases": [
    { "channel_id": 123, "feed_url": "https://example.com/feed.xml", "site_url": "https://example.com/", "use_proxy": false }
  ]
}
```

`use_proxy` は、ホストが `proxy_required_domains` に載っているかどうか。

### `POST /fetcher/channels/:channel_id/guid_lookups`

リクエスト: `{ "guids": ["...", "..."] }`
レスポンス: `{ "new_guids": ["..."] }`

今の `only_non_existing` と同じく、そのチャンネルの `items.guid` に無いものを返す。fetcher は entry の entry_id と url の両方を送り、両方とも無かった entry を新しいものとみなす。

読み取りだけで冪等な API なので、意味としては GET が合う。ただし guid は1フィードで数千件・数百KBになることがあり、URL に載せられない。
本来は RFC 10008 の QUERY メソッドが合うが、2026-10 時点で Puma 8.0.2 は QUERY を 501 で拒否し、Rails 8.1 もメソッドとして知らない (Cloudflare と Heroku のルーターは通す)。そのため POST にし、この事情をコントローラのコメントに残す。

### `POST /fetcher/leases/:channel_id/result`

リクエスト:

```json
{
  "fetched": true,
  "error": null,
  "final_url": "https://example.com/feed.xml",
  "proxy_used": false,
  "register_proxy_domain": false,
  "channel": {
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
      "data": { "entry_id": "...", "title": "...", "url": "...", "published": "...", "summary": "...", "itunes_subtitle": "...", "enclosure_url": "...", "enclosure_type": "audio/mpeg" }
    }
  ],
  "latest_guids": ["...", "..."]
}
```

- `entries` は新しいものだけを、公開日時の昇順で送る。中身は fetcher の整形済みの値 (golden と同じもの)
- `channel` が null のときは、チャンネル情報を更新しない (Rails の `build_from` が nil を返す形式と同じ)
- `latest_guids` は、フィードの中で公開日時が新しい2件の entry の entry_id と url。新着通知の判定に使う
- 取得に失敗したときは `fetched: false` にし、`error` に `{ "kind": "http_status" | "timeout" | "connect" | "too_large" | "parse" | "deadline" | ..., "message": "..." }` を入れる

レスポンス:

- 200: 保存まで済んだ。`{ "created": 3, "skipped": 0 }`
- 202: entries が多いので、item の保存以降をジョブに回した (節5)
- 409: lease がこのワーカーのものでないか、期限が切れている。何も書かない
- 422: リクエストの形が不正

## 5. 結果の保存 (`FetchResultApplier`)

`app/services/fetch_result_applier.rb` に置く。今の `ChannelItemsUpdaterJob` と同じ順で処理し、各手順の例外は Sentry に送って次の手順に進む (ジョブの `handle_error` と同じ考え方)。

1. **lease の確認**: lease の行をロックし、送ってきたワーカーのもので期限内かを確かめる。違えば 409
2. **取得の失敗**: `fetched: false` なら、エラーの種類をログに残して手順6へ。Sentry には送らない (今の Rails は取得失敗も Sentry に送っていて、送信量を押し上げている)。失敗の多さは節7の監視とログで見る
3. **リダイレクト**: `final_url` が今の `feed_url` と違えば更新する。行き先が別のチャンネルとして既にあれば `ChannelStopper` を作り、手順4と5を飛ばす (今の `fetch_and_save_items` と同じ)
4. **チャンネル情報**: `channel` の各値で `channel.update` する。`save_from` と同じく bang なしにして、バリデーションに落ちたら更新せずに進む。`notify_channel_change` は after_commit でそのまま動く。`register_proxy_domain` が true なら `proxy_required_domains` にホストを登録する
5. **item の保存**: entries を1件ずつ `Item.new(channel_id:, ...)` で保存する
   - `channel.items` の association を通さない。無効な Item が association のキャッシュに残らないので、#828 の原因がこの経路では起きない
   - バリデーションに落ちたものは、今と同じく Sentry に warning を送って飛ばす
   - 一意制約の違反 (同じ guid が同時に保存された場合) は飛ばす
   - 新しく保存した item のうち、guid が `latest_guids` に含まれるものは `ItemCreationNotifierJob.perform_later` で通知する
6. **チェック済みの記録と再計算**: `mark_items_checked!`、`set_check_interval!`、`adjust_schedules!` を今のメソッドのまま呼ぶ
7. **lease を削除する**

### 大きな結果

Heroku のルーターは30秒でリクエストを打ち切る。entries が200件を超えたら、リクエストの中では手順1〜4だけを行って 202 を返し、手順5〜7は `FetchResultApplyJob` に任せる (entries はジョブの引数に入れる)。
lease はジョブが終わるまで残す。ジョブの中で lease を延ばす (`leased_until` を今 + 10分にする) ので、ジョブを待つ間に同じチャンネルが貸し出されることはない。

### #828 について

この経路では起きないが、Rails に残る手動取得と初回取得では起きる。#828 の「望ましい直し方」(`set_check_interval!` を `update_column` にする) を、2b の最初に別の PR で入れる。

## 6. fetcher (Rust)

### `run` サブコマンド (常駐)

今の `shadow` の隣に足す。取得・フィルタ・パース・整形・OGP は影モードと同じ処理を使う。

- 設定 (環境変数): `FETCHER_API_URL`、`FETCHER_TOKEN`、`CONCURRENCY` (既定 8)、`FEED_PROXY_URL` / `FEED_PROXY_SECRET` (任意)
- 空いている枠の数だけ `POST /fetcher/leases` で借りる。1件も返ってこなければ60秒待つ
- 1チャンネルの処理: 取得 → フィルタ → パース → 整形 → `guid_lookups` → 新しい entry の OGP → `result`
- **1チャンネルの持ち時間は5分**。lease の期限 (10分) より短くし、超えたら打ち切って `fetched: false`、`kind: "deadline"` で結果を送る
- **`result` の送り直し**: 接続エラーと 5xx は、間隔を延ばしながら最大5回送り直す。409 なら捨てる。送れなかった結果は捨て、lease の期限切れで次の貸し出しに回る
- SIGTERM を受けたら新しい貸し出しを止め、処理中のチャンネルを (持ち時間の範囲で) 終えてから終わる
- systemd の unit ファイルのサンプルを `fetcher/` に同梱する

### 影モードから直すところ

- チャンネル情報の `feed_url` をリダイレクト後の URL にする (2a からの持ち越し。Rails の `save_from` は `final_feed_url` を使う)
- **本文サイズの上限を 20MB から 64MB に上げる**。本番に 57MB のフィードがあり、Rails は読めている。超えたら `too_large` で失敗にする
- **SSRF の対策**: 自宅で動かすので、`feed_url` や OGP の URL がプライベートアドレスを指していると家の LAN に届いてしまう。今の `address_guard` に、まだ塞いでいないレンジ (NAT64 `64:ff9b::/96`、6to4 `2002::/16`、Teredo `2001::/32` など) を足す (IPv4 射影アドレスは対応済み)。リダイレクトのたびに行き先のアドレスを確かめる
- **Rust が扱えない形式** (JSON Feed など): 切り替えの前に本番の件数を数える。あれば、ロールアウトの対象から外して Rails に残すか、その時点で対応を決める

### ログ

構造化ログを標準出力に出す (journald に残る)。fetcher からは Sentry に送らない。止まっているかどうかは、節7の遅れの監視で Rails 側から見る。

## 7. 段階移行・監視・切り替え

### 段階移行

- 環境変数 `ROLLOUT_PERCENT` (既定 0) を Rails にだけ置く
  - `POST /fetcher/leases` は `channel_id % 100 < ROLLOUT_PERCENT` のチャンネルだけを貸し出す
  - `Channel.fetch_and_save_items` (`ChannelItemsFetcherJob`) は、それ以外のチャンネルだけをジョブに積む
- 0 → 10 → 50 → 100 と上げる。0 では API をデプロイして、fetcher が空振りすることを確かめる
- 各段階で見るもの: Sentry、1時間あたりの item 作成数 (上げる前との比較)、遅れの監視、fetcher のログの 409 と送り直しの回数

### 遅れの監視

`FetcherLagMonitorJob` (recurring、15分ごと) を足す。

- ロールアウトの対象で、`not_stopped` かつ「最後のチェックから `check_interval_hours` + 1時間以上たっている」チャンネルを数える
- 10件を超えていたら Discord に投稿する。超えている間の投稿は1時間に1回までにする

### 切り替え (100% になってから)

1. `SOLID_QUEUE_IN_PUMA=1` を設定し、worker dyno を 0 にする
2. web dyno のメモリ (R14) と DB の接続数を数日見る。Puma のスレッドに Solid Queue の分が加わるので、`database.yml` の pool の大きさも確かめる
3. 影モードを止め、dispatcher の Worker と Hyperdrive を削除する

### 巻き戻し

`ROLLOUT_PERCENT=0` にし、worker dyno を 1 に戻す (`SOLID_QUEUE_IN_PUMA` も外す)。lease は10分で切れるので、後始末は要らない。

## 8. テスト

### Rails

- `/fetcher/*` の request テスト
  - 認証 (トークンが無い・違う)
  - 貸し出しの条件: チェックが必要か、停止中か、lease 中か、同じホストが lease 中か、ロールアウトの割合、期限切れの lease の削除、同じバッチの中でホストが重ならないこと
  - 他のワーカーの lease や期限切れの lease への `result` が 409 になり、何も書かないこと
  - `guid_lookups` の判定
- `FetchResultApplier` の単体テスト
  - リダイレクト (行き先が既にあれば停止)
  - チャンネル情報の更新と「Channel updated」の通知
  - item の保存と、`latest_guids` に含まれるものだけの通知
  - バリデーションに落ちた entry を飛ばすこと
  - 取得に失敗しても、チェック済みの記録と再計算が進むこと
  - 200件を超えたらジョブに回すこと
- `ChannelItemsFetcherJob` がロールアウトの対象外だけを積むこと
- `FetcherLagMonitorJob` のしきい値と、投稿の間引き

### Rust と Rails の契約

golden のフィクスチャから作った `result` のサンプル (`fetcher/testdata/result/*.json`) をリポジトリに置く。

- Rust: 自分の出力がこのファイルと一致すること
- Rails: このファイルを `FetchResultApplier` に通すと、golden どおりの item ができること

どちらか片方だけ形を変えると、どちらかのテストが落ちるようにする。

### fetcher

- `run` のループをモックサーバで確かめる: 枠の数だけ借りる、空なら待つ、持ち時間の打ち切り、`result` の送り直し、409 で捨てる
- SSRF: 塞ぐレンジの境界と、リダイレクト先での判定

### 手元での通し確認

開発環境の Rails に向けて fetcher の `run` を動かし、貸し出し → 保存 → 通知 → 再計算までが一周することを確かめる。

## 9. コスト

| 項目 | 変化 |
|---|---|
| worker dyno (Standard-2X) | −$50 |
| Cloudflare Workers Paid | 不要 (親の設計書では +$5) |
| 合計 | 約 $117 → 約 $67 / 月 |
