# dispatcher

[fetcher](../fetcher/README.md) (各マシンで動く Rust 製のワーカー) と本番 DB の間に立つ Cloudflare Worker。
DB へは Hyperdrive 経由で接続する。今のエンドポイントはすべて読み取り専用で、本番 DB には書き込まない。
コードの約束だけに頼らないよう、すべてのルートは `BEGIN READ ONLY` のトランザクションの中で動かしている
(ルートが使う `c.get("sql")` はそのトランザクション)。書き込もうとすると DB 側で
`cannot execute ... in a read-only transaction` になる。

リクエストごとに `{"worker","method","path","status"}` の1行を Workers Logs に出す (トークンやクエリ文字列は出さない)。

設計は [docs/superpowers/specs/2026-09-25-feed-fetcher-offload-design.md](../docs/superpowers/specs/2026-09-25-feed-fetcher-offload-design.md) を参照。

## エンドポイント

どれも `Authorization: Bearer <token>` が必要。トークンが違えば `401`、`WORKER_TOKENS` が壊れていれば `500`。

| メソッドとパス | 説明 |
| --- | --- |
| `GET /shadow/channels?max=20&order=priority&scope=due` | 今取り込むべきチャンネルと保存済みのチャンネル情報、プロキシ必須ドメインの一覧を返す。`max` は 1〜100、`order` は `priority` か `random`、`scope` は `due` (既定、今取り込むべきものだけ) か `all` (停止中を除く全チャンネルから検証用にサンプル)。同じホストのチャンネルは1回に1件まで |
| `POST /channels/:channel_id/new-guids` | `{ "entries": [{ "entry_id", "url" }] }` を受け取り、それぞれが未保存 (新規) かどうかを返す (最大1000件) |
| `POST /shadow/channels/:channel_id/items` | `{ "guids": [...] }` を受け取り、保存済みの items を返す (最大1000件)。各 item の `created_at` は Rails が保存した時刻 (UTC、`...Z`) |

## テスト

Rails のテスト用 DB をそのまま使うので、先にスキーマを用意する
(テストはテーブルを TRUNCATE するため、`TEST_DATABASE_URL` が未設定か DB 名が `_test` で終わらなければ起動時に止まる):

```bash
docker compose run --rm -e RAILS_ENV=test web rails db:prepare
docker compose run --rm dispatcher npm test
```

型チェックは `docker compose run --rm dispatcher npm run typecheck`。

## ワーカーのトークンの発行

トークンはマシン (ワーカー) ごとに1つ発行する。dispatcher にはトークンそのものではなく SHA-256 (16進小文字) だけを置く。

```bash
TOKEN=$(openssl rand -hex 32)
printf %s "$TOKEN" | shasum -a 256
```

出たハッシュを「ワーカー名 → ハッシュ」の JSON にまとめて secret に登録する (既存のワーカーの分も含めて丸ごと登録し直す):

```bash
npx wrangler secret put WORKER_TOKENS
# 入力例: {"machine-a":"<sha256 hex>","machine-b":"<sha256 hex>"}
```

`$TOKEN` はそのマシンの `FETCHER_TOKEN` に設定し、リポジトリには書かない。

## Hyperdrive

作成 (出力された id を `wrangler.toml` の `[[hyperdrive]]` の `id` に書く):

```bash
npx wrangler hyperdrive create feeeed-db --caching-disabled --connection-string="$(heroku config:get DATABASE_URL -a feedhub)"
```

`--caching-disabled` を付けてクエリ結果のキャッシュを切る。Hyperdrive は既定で読み取りクエリの結果を
しばらくキャッシュするため、そのままだと「今取り込むべきチャンネル」や「この guid は保存済みか」が
古い結果で返り、Rails の取り込みと突き合わせる意味が薄れる (新規判定がずれる)。
既存の設定なら `npx wrangler hyperdrive update <id> --caching-disabled` で切り替える。

Heroku Postgres の認証情報が変わったとき (Heroku 側の定期的なローテーションなど):

```bash
npx wrangler hyperdrive update <id> --connection-string="$(heroku config:get DATABASE_URL -a feedhub)"
```

## デプロイ

```bash
npx wrangler deploy
```

`wrangler.toml` で Workers Logs (`[observability] enabled = true`) を有効にしてある。
