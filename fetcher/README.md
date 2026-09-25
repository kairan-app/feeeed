# fetcher

フィードの取得・パース・整形を Rails の外で行う Rust 製のワーカー。
Rails の取り込み処理 (`Channel#fetch_and_save_items`) と同じ規則でフィードを整形し、
今は「影モード」として本番の保存済みデータと突き合わせるだけで、DB には書き込まない。

設計は [docs/superpowers/specs/2026-09-25-feed-fetcher-offload-design.md](../docs/superpowers/specs/2026-09-25-feed-fetcher-offload-design.md) を参照。
ワーカーが話しかける API は [dispatcher](../dispatcher/README.md) (Cloudflare Worker)。

## ビルド

```bash
cd fetcher
cargo build --release
# => target/release/fetcher
```

テスト・lint (CI と同じ):

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

## 環境変数

| 変数 | 必須 | 説明 |
| --- | --- | --- |
| `FETCHER_API_URL` | yes | dispatcher のベース URL (例: `https://feeeed-dispatcher.example.workers.dev`) |
| `FETCHER_TOKEN` | yes | このマシン用のワーカートークン (dispatcher の `WORKER_TOKENS` にハッシュを登録したもの) |
| `FETCHER_CONCURRENCY` | no | 同時に処理するチャンネル数。既定 `8`。同じホストへは常に同時1本・1秒以上の間隔 |
| `FETCHER_USER_AGENT` | no | フィード・OGP 取得時の User-Agent。既定 `Faraday v2.14.3` (Rails と同じ) |
| `FEED_PROXY_URL` | no | プロキシ必須ドメイン向けのプロキシ URL。`FEED_PROXY_SECRET` とセットで使う |
| `FEED_PROXY_SECRET` | no | プロキシの共有シークレット |

いずれも同名のコマンドラインフラグ (`--api-url` など) でも渡せる。

## 影モード (`fetcher shadow`)

dispatcher から「今取り込むべきチャンネル」を受け取り、フィードを取得・整形して、
本番に保存済みの items と項目ごとに比べた結果を JSON Lines で書き出す。

```bash
export FETCHER_API_URL=https://feeeed-dispatcher.example.workers.dev
export FETCHER_TOKEN=...   # 手元の秘密情報から読み込む
target/release/fetcher shadow --max 50 --order random --out tmp/shadow-report.jsonl
```

- `--max`: 1回に処理するチャンネル数 (1〜100、既定 50)
- `--order`: `priority` (Rails のスケジューラと同じ優先度順) か `random`
- `--out`: レポートの出力先 (既定 `tmp/shadow-report.jsonl`。親ディレクトリが無ければ作る)

レポートには本番のフィード URL や保存済みの値が入るので**コミットしない**。
`tmp/` と `*.jsonl` (リポジトリ直下と `fetcher/` 直下) は gitignore してある。

ログは `RUST_LOG=info` などで出せる。

取得先がループバック・プライベート (10/8, 172.16/12, 192.168/16)・リンクローカル (169.254/16, fe80::/10)・
CGNAT (100.64/10)・ULA (fc00::/7) などのアドレスなら接続しない (IP を直接書いた URL も、名前解決の結果も、
リダイレクト先も調べる)。応答本文は 20 MiB で打ち切る。

### レポートの読み方

1行が1チャンネル。主なキー:

- `status`: `ok` なら比較まで完了。それ以外のときは `error` に理由が入る
  - `fetch_error`: 取得の失敗。`error` は `種類: 詳細` の形。種類は `http_status`・`timeout`・`connect`・`too_many_redirects`・`blocked_address` (内部ネットワークのアドレス)・`too_large` (20 MiB 超)・`other`
  - `parse_error`: パースの失敗
  - `dispatcher_error`: dispatcher の呼び出しの失敗 (`error` は `呼び出し: 詳細` の形)。フィード側の問題ではない
- `format` / `applied_filters`: 判定したフィード形式と適用したフィルタ
- `entries_in_feed` / `new_entries`: フィード内のエントリ数、dispatcher が未保存と判定したエントリ数
- `existing_flagged`: dispatcher が保存済みと判定したエントリ数
- `entries_compared`: そのうち、保存済みの item を guid で引けて項目ごとに比べたエントリ数。
  `existing_flagged` より少なければ、その差の分だけ `field: "guid"` の差分が出る
  (entry_id と url のどちらかで保存済みと判定されたが、Rails が保存した guid と Rust の guid が違う)
- `new_guids`: 未保存と判定したエントリの `guid` と `published_at`。Rails が次の取り込みで同じものを保存したかを後で確かめられる
- `skipped`: Rails と同じ規則で保存対象外にしたエントリ
- `diffs`: 一致しなかった項目。`field`、`guid` (チャンネル単位の項目なら null)、`rust`、`rails` の値、
  entry の差分なら `item_created_at` (Rails がその item を保存した時刻)

entry の差分には、parser の違いのほかに、Rails が保存したあとでフィード側がタイトルや本文を書き換えた
(drift) ものも混ざる。Rails は一度保存した item を更新しないので、古い item ほど drift の可能性が高い。
parser の違いを探すときは、最近保存された item の差分に絞るとよい。

項目ごとの差分の数:

```bash
jq -s 'map(.diffs[]) | group_by(.field) | map({field: .[0].field, count: length})' tmp/shadow-report.jsonl
```

guid がずれたエントリ (保存済みと判定されたのに保存済みの item を引けなかったもの):

```bash
jq -c 'select(.existing_flagged != .entries_compared) | {channel_id, feed_url, guids: [.diffs[] | select(.field == "guid") | .guid]}' tmp/shadow-report.jsonl
```

新規と判定したエントリの一覧:

```bash
jq -c '{channel_id} + (.new_guids[])' tmp/shadow-report.jsonl
```

最近 (直近7日) 保存された item の差分だけ (drift を除いて parser の違いを探す):

```bash
jq -c '.channel_id as $c | .diffs[] | select(.item_created_at != null and .item_created_at > (now - 7*86400 | todate)) | {channel_id: $c} + .' tmp/shadow-report.jsonl
```

エラーの種類ごとの数:

```bash
jq -s 'map(select(.status != "ok")) | group_by([.status, (.error | split(":")[0])]) | map({status: .[0].status, kind: (.[0].error | split(":")[0]), count: length})' tmp/shadow-report.jsonl
```

## golden テスト

`testdata/fixtures/*.xml` は手書きの合成フィード (第三者のコンテンツは入れない)。
それぞれを Rails の取り込み処理にかけた結果が `*.golden.json` で、`tests/golden.rs` がこれと Rust の出力を比べる。
`<name>.url` があればそれをフィードの URL として使う (無ければ `https://example.com/<name>/feed.xml`)。

フィクスチャを足したり Rails 側の挙動が変わったりしたら golden を作り直す:

```bash
docker compose run --rm web rails "fetcher:golden[fetcher/testdata/fixtures]"
```

新しいフィクスチャは `tests/golden.rs` の `golden_tests!` にも名前を足す。

## 比較用コーパス

本番のフィードを手元に落として、Rails と Rust の結果が一致するかを確かめる。
`testdata/corpus/` と `tmp/` は gitignore 下。**本番のフィード本文はコミットしない** (リポジトリは public)。

1. 本番から feed_url を選ぶ (読み取り専用)。フィルタが適用されているチャンネルは全件、ほかはホストごとに1件ずつ選んでから、ホスト自体も無作為に20件選ぶ
   (内側の `DISTINCT ON` だけだとホスト名のアルファベット順の先頭に偏るため、外側で `random()` で並べ替える):

   ```bash
   heroku pg:psql -a feedhub -c "
   SET default_transaction_read_only = on;
   (SELECT feed_url FROM channels WHERE applied_filters::text <> '[]')
   UNION ALL
   (SELECT feed_url FROM (
      SELECT DISTINCT ON (substring(feed_url from '://([^/:]+)')) feed_url FROM channels c
      WHERE NOT EXISTS (SELECT 1 FROM channel_stoppers s WHERE s.channel_id = c.id)
      ORDER BY substring(feed_url from '://([^/:]+)'), random()
    ) per_host ORDER BY random() LIMIT 20);" \
     | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -E '^https?://' > tmp/corpus-urls.txt
   ```

   `heroku pg:psql` は psql の `-t -A` を受け付けないので、表の出力から URL の行だけを抜き出す。

2. フィードを落とす (1件ごとに1秒空ける):

   ```bash
   fetcher/scripts/collect_corpus.sh tmp/corpus-urls.txt
   ```

3. golden を作る。開発用 DB に同じ feed_url のチャンネルがあると一意制約で失敗するので、空のテスト用 DB で動かす:

   ```bash
   docker compose run --rm -e RAILS_ENV=test web rails "fetcher:golden[fetcher/testdata/corpus]"
   ```

   Rails 側で例外になるフィード (`FAILED` と表示されるもの) は golden が作られず、比較の対象外になる。

4. 比べる:

   ```bash
   cd fetcher && cargo run -- golden-check testdata/corpus
   ```

   最後に `N / M matched` が出る。一致しないものは Rust 側を Rails に合わせて直し、
   原因になった形を最小の合成フィクスチャにして `testdata/fixtures/` に足す。
