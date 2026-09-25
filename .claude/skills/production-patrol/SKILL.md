---
name: production-patrol
description: 本番環境 (Heroku の feedhub) を見回って、失敗ジョブ・止まったチャンネル・キューの滞留・Heroku のエラー・Sentry の未解決 issue を洗い出し、要対応のものを GitHub Issue にする。無人で定期実行されることを前提に、途中でユーザーに質問しない。ユーザーが`/production-patrol`を実行したとき、または「本番の様子見て」「本番巡回して」のように依頼してきたときに使う。
---

本番環境を見回って、放っておくと壊れ続けるものを見つけ、要対応のものを GitHub Issue にする。
`/loop` や cron で無人のまま定期実行されることを前提にしているので、途中でユーザーに質問せず最後まで進める。
直すのはこのスキルの範囲外。Issue を元に別の作業として直す。

## 守ること

- 本番に対しては読み取りだけ。失敗ジョブの破棄、dyno の再起動、Sentry issue の resolve などの書き込みはしない
- DB は必ず `SET default_transaction_read_only = on;` を打ってから読む (`queries.sql` の先頭に入っている)
- Issue やこの会話の報告に、ユーザーのメールアドレスや名前などの個人情報を書かない。ID と件数で表す

## 1. 見回る

5つの領域を順に見る。コマンドが失敗したら、その領域は「確認できず」として理由を控え、次に進む。

### 1-1. DB (失敗ジョブ・止まったチャンネル・キュー)

```bash
heroku pg:psql -a feedhub --file .claude/skills/production-patrol/queries.sql
```

- **失敗ジョブ**: ジョブ × 例外クラスごとの件数と、いつからいつまで出ているか。特定の `channel_id` に偏っていないか。同じ失敗が毎時積まれ続けているものは、エラー処理そのものが壊れている可能性がある (#805 はこれだった)。気になる組み合わせは `solid_queue_failed_executions.error` の backtrace を読んで、どこで落ちているかまで確かめる
- **止まったチャンネル**: 停止中 (`channel_stoppers`) を除いて、チェック間隔の3倍かつ24時間以上チェックされていないチャンネル。失敗ジョブの `channel_id` と重なるなら同じ原因の可能性が高い
- **キュー**: ready が溜まっている、一番古い ready が数十分以上前、claimed が長く残っている、などは詰まりのサイン
- **ワーカー**: heartbeat が数分以上途絶えているプロセス
- **DB 接続数**: Heroku Postgres essential-1 の上限は20。使い切ると worker の heartbeat が書けなくなり、ジョブも recurring タスクも止まる (Hyperdrive 経由の影モード検証で一度起きた)。15を超えていたら要対応、どの `application_name` が多いかも見る
- **recurring タスク**: `config/recurring.yml` のスケジュールと見比べて、最終実行が遅れているもの。worker は1プロセスで scheduler も兼ねているので、worker が止まると全タスクが同じ時刻から揃って途切れる
- **`SolidQueue::Processes::ProcessPrunedError`**: 実行中の worker プロセスが heartbeat を失って刈り取られた印。その時刻を recurring タスクの途切れや Heroku の dyno の再起動・crash と突き合わせる

### 1-2. Heroku

```bash
heroku ps -a feedhub
heroku releases -a feedhub -n 5
heroku logs -a feedhub -n 1500
```

- dyno が `crashed` になっていないか、再起動が多すぎないか
- ログの `code=H\d\d` (H12 タイムアウトなど)、`R14`/`R15` (メモリ超過)、`Error R`、`status=5\d\d` を拾って種類ごとに数える
- 直近のリリースと、エラーが増え始めた時刻が重なっていないか

### 1-3. Sentry

`.sentryclirc` で org/project は設定済み。

```bash
sentry-cli issues list --status unresolved
```

イベント数と種類で Tier に分ける。

- **Tier 1 (コード修正で直せる)**: バリデーションエラー、nil 参照、型エラー、エンコーディングエラーなど
- **Tier 2 (調査が必要)**: N+1 クエリ、パフォーマンス系
- **Tier 3 (外部要因・要監視)**: HTTP 4xx/5xx、タイムアウト、接続エラー
- **Tier 4 (無視してよい)**: 外部サービスの一時的な障害。`Faraday::TimeoutError` などは基本ここ

warning レベルの issue はデータ品質の問題なので、すぐ直す必要はないが、増えていないかの傾向は見る。
DB や Heroku で見つけたものと同じ原因の issue があれば、まとめて扱う。

## 2. 判定する

領域ごとに「要対応 / 様子見 / 問題なし / 確認できず」を付ける。

- **要対応**: 放っておくと壊れ続けるもの、利用者に影響が出ているもの。例: 同じ失敗ジョブが毎日積まれ続けている、チャンネルのチェックが止まっている、recurring タスクが途切れている、DB 接続数が15を超えている、Sentry の Tier 1
- **様子見**: 単発や少数で、増えていないもの。Sentry の Tier 2〜3、外部サービス起因の失敗など
- **問題なし**: 何も見つからなかった
- **確認できず**: コマンドが失敗した、権限で止められたなど

領域をまたいで同じ原因と思われるものは1項目にまとめる。

## 3. 要対応を Issue にする

要対応の項目は、ユーザーに確認せずに Issue にする。様子見は Issue にせず、報告だけにする。

### 重複を避ける

このスキルは何度も繰り返し実行されるので、同じ問題の Issue を何度も作らないようにする。

1. `production-patrol` ラベルが無ければ作る: `gh label create production-patrol --description "/production-patrol が見つけた本番の異常" --color B60205` (既にあればエラーになるので無視してよい)
2. 作る前に、開いている Issue に同じ問題が無いか確かめる。`gh issue list --state open --label production-patrol` に加えて、ラベルの無い手動の Issue もあるので `gh issue list --state open --search "<ジョブ名や例外クラスなどのキーワード>"` でも探す
3. 同じ問題の Issue があれば、新しく作らない。コメントも足さない (3時間おきにコメントが積もるのを避けるため)。報告にその Issue の URL を書く
4. 閉じた Issue と同じ問題が再発していそうなら、新しい Issue を作り、本文で閉じた Issue に触れる

### 本文の形

`gh issue create --label production-patrol` で作る。読む人はこの巡回の場にいないので、Issue だけで状況がわかるように書く。

```markdown
## 概要
何が起きていて、何が困るのか。

## 症状 (YYYY-MM-DD HH:MM JST 時点、本番)
件数、期間、影響範囲、backtrace の先頭など。

## 原因 (推定)
コードの該当箇所 (`path:line`) を示しながら、なぜそうなるかを順に書く。
推定の確からしさ (backtrace で確認済み / 状況からの推測) も書く。

## 直し方の方向性
複数あれば並べ、どれが望ましいかも書く。直したあとの後始末 (溜まった失敗ジョブの破棄など) もここに書く。

## 再現テストの案
既存テストのどれが書き方の参考になるか。

## 確認用のクエリ・コマンド (本番、読み取り専用)
直ったかを確かめるときに使えるもの。

---
この Issue は `/production-patrol` が自動で作成しました。
```

## 4. 報告する

最後に、次の形で報告して終わる。質問はしない。

- 実行日時 (JST)
- 領域ごとの判定の表。問題なしの領域は1行で済ませる
- 要対応・様子見の項目それぞれについて、何が起きているかと推定の原因を1〜2行で
- 今回作った Issue の URL と、既存の Issue があったので作らなかったものの URL
- 確認できなかった領域と、その理由 (権限で止められたなら、どのコマンドを許可すればよいか)
