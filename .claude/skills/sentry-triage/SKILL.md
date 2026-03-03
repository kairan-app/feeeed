---
name: sentry-triage
description: Sentryの未解決issueをトリアージして、対応可能なものを修正する
---

Sentryの未解決issueをトリアージしてください。`.sentryclirc` で org/project は設定済みです。

## 手順

### 1. 現状把握
- `sentry-cli issues list --status unresolved` で未解決issueを取得
- `sentry-cli issues list --status unresolved --query "level:warning"` でwarningレベルも確認

### 2. 分類
issueをイベント数と種類で以下のTierに分類して一覧表示:

- **Tier 1（コード修正で対応可能）**: バリデーションエラー、nil参照、型エラーなど
- **Tier 2（調査が必要）**: N+1クエリ、パフォーマンス系
- **Tier 3（外部要因）**: HTTP 4xx/5xx、タイムアウト、接続エラーなど
- **Tier 4（無視可能）**: 外部サービスの一時的障害

### 3. 対応提案
Tier 1のissueについて、修正方針を提案する。提案にはイベント数と影響範囲を含める。

### 4. 修正（ユーザー承認後）
- TDDアプローチ: テストを先に書いてから修正
- コミットはissueごとに分ける
- 修正が複数あればPRにまとめる

### 注意事項
- Sentry issueの詳細を見るには `sentry-cli issues list` の出力を参照
- warningレベルのissueはデータ品質の問題であり、即座の修正は不要だが傾向は把握する
- 外部サービス起因のエラー（Faraday::TimeoutError等）は基本的に無視してよい
