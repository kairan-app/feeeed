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
target/release/fetcher shadow --max 50 --order random --out report.jsonl
```

- `--max`: 1回に処理するチャンネル数 (1〜100、既定 50)
- `--order`: `priority` (Rails のスケジューラと同じ優先度順) か `random`
- `--out`: レポートの出力先 (既定 `shadow-report.jsonl`)

ログは `RUST_LOG=info` などで出せる。

### レポートの読み方

1行が1チャンネル。主なキー:

- `status`: `ok` なら比較まで完了。`fetch_error` (取得の失敗。`error` は `種類: 詳細` の形) か `parse_error` (パースの失敗) のときは `error` に理由が入る
- `format` / `applied_filters`: 判定したフィード形式と適用したフィルタ
- `entries_in_feed` / `new_entries` / `entries_compared`: フィード内のエントリ数、未保存のエントリ数、保存済みと比べたエントリ数
- `skipped`: Rails と同じ規則で保存対象外にしたエントリ
- `diffs`: 一致しなかった項目。`field`、`guid` (チャンネル単位の項目なら null)、`rust`、`rails` の値

項目ごとの差分の数:

```bash
jq -s 'map(.diffs[]) | group_by(.field) | map({field: .[0].field, count: length})' report.jsonl
```

エラーの種類ごとの数:

```bash
jq -s 'map(select(.status != "ok")) | group_by(.error | split(":")[0]) | map({kind: .[0].error, count: length})' report.jsonl
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

1. 本番から feed_url を選ぶ (読み取り専用)。フィルタが適用されているチャンネルは全件、ほかはホストがばらけるように選ぶ:

   ```bash
   heroku pg:psql -a feedhub -c "
   SET default_transaction_read_only = on;
   (SELECT feed_url FROM channels WHERE applied_filters::text <> '[]')
   UNION ALL
   (SELECT DISTINCT ON (substring(feed_url from '://([^/:]+)')) feed_url FROM channels c
    WHERE NOT EXISTS (SELECT 1 FROM channel_stoppers s WHERE s.channel_id = c.id)
    ORDER BY substring(feed_url from '://([^/:]+)'), random() LIMIT 20);" \
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
