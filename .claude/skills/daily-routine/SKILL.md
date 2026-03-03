---
name: daily-routine
description: 1日のはじめに実行する定常タスク（Dependabot + Sentry）
---

1日のはじめの定常タスクを順に実行してください。

## 実行順序

### Step 1: Dependabot PRの処理
`/dependabot-merge` スキルの内容を実行してください:
- `gh pr list --author "app/dependabot" --state open --json number,title,url,statusCheckRollup` でDependabot PRを一覧取得
- patch/minor + CI greenのPRは自動マージ
- majorは確認を取る
- 結果サマリーを表示

### Step 2: Sentryトリアージ
`/sentry-triage` スキルの内容を実行してください:
- `sentry-cli issues list --status unresolved` で未解決issueを取得
- Tier分類して一覧表示
- 対応可能なものがあれば修正方針を提案

## 完了時
両ステップの結果をサマリーとして表示してください。
