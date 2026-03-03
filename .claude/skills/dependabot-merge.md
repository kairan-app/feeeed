---
name: dependabot-merge
description: Dependabot PRを確認して、patch/minorはCI greenなら自動マージする
---

Dependabotが出しているPull Requestを確認し、安全なものをマージしてください。

## 手順

1. `gh pr list --author "app/dependabot" --state open --json number,title,url,statusCheckRollup` でDependabot PRを一覧取得
2. PRが無ければ「Dependabot PRはありません」と報告して終了
3. 各PRについて以下を判定:
   - PRタイトルからバージョンアップの種類を判定（semverのpatch/minor/major）
     - "from X.Y.Z to X.Y.W" のようなパターンでmajor/minor/patchを識別
   - `gh pr checks <PR番号>` でCIの状態を確認
4. 結果を一覧表示した上で、以下のルールで処理:
   - **patch/minor + CI全てpass**: `gh pr merge <PR番号> --merge` で自動マージ
   - **major + CI全てpass**: 内容を表示し、ユーザーに確認を取ってからマージ
   - **CI失敗/pending**: マージせず、状況を報告
5. 処理結果のサマリーを表示（マージ済み/スキップ/要確認の件数）
