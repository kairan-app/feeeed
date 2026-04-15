# rururu CLI

rururu (feeeed) の GraphQL API を叩くためのコマンドラインツール。

## ビルド

```sh
cd cli
go build -o rururu
```

生成された `rururu` バイナリを `$PATH` の通った場所に置くと `rururu` コマンドとして呼べる。

```sh
# 例: ~/.local/bin など好きな場所へ
mv rururu ~/.local/bin/
```

## 使い方

### プロファイル

ローカル/本番など複数の環境を同時に管理できる(`gh`/`aws`/`kubectl`方式)。

```sh
rururu profiles list                    # 登録済プロファイル一覧 (* がデフォルト)
rururu profiles use prod                # デフォルトを切替
rururu --profile prod whoami            # コマンド単位でプロファイル指定
RURURU_PROFILE=prod rururu whoami       # 環境変数でも指定可
```

優先順位: `--profile` > `RURURU_PROFILE` > 設定ファイルの `default` > プロファイルが1つだけならそれ。

### ログイン

Web側の `/my/app_passwords` で発行した App Password を手元に控えておく。

```sh
rururu auth login                       # default プロファイルに登録
rururu auth login --profile prod        # prod プロファイルに登録
# Profile: prod
# Endpoint [https://fh.lvh.me/graphql]: https://feedhub.herokuapp.com/graphql
# App Password: (貼り付け、入力は画面に表示されない)
# Logged in as yourname (profile: prod)
```

### 自分の情報を見る

```sh
rururu whoami
# yourname <you@example.com> (profile: default)
```

### 足あと(Pawprint)を見る

```sh
rururu pawprints list
# 2026-04-15 21:30  88  juneboku  「タイトル」  (チャンネル名)  💬 メモ

# スコープ指定 (my=自分(デフォルト) / all=全員 / to_me=自分の所有チャンネルへ)
rururu pawprints list --scope all

# 件数指定 + ページング(末尾の --before <id> をコピペするだけ)
rururu pawprints list --limit 100
rururu pawprints list --before 81

# 構造化出力
rururu pawprints list --json
```

### 未読記事を見る

```sh
rururu unreads list
# 2026-04-15 21:24  34686  「タイトル」  (チャンネル名)  https://example.com/...

# 期間指定 (デフォルト3日)
rururu unreads list --range-days 7

# ChannelGroup / SubscriptionTag で絞り込み
rururu unreads list --channel-group 12
rururu unreads list --tag 5

# 件数指定 + ページング
rururu unreads list --limit 100
rururu unreads list --before 34683

# 構造化出力
rururu unreads list --json
```

### ログアウト

指定したプロファイルを設定ファイルから削除する。API側でトークンを revoke したい場合は Web 画面から行う。

```sh
rururu auth logout                      # 現在のデフォルトプロファイルを削除
rururu auth logout --profile prod       # 特定のプロファイルだけ削除
```

### endpointの一時上書き

グローバルフラグ `--endpoint` で都度変更できる。

```sh
rururu --endpoint https://fh.lvh.me/graphql whoami
```

## 設定ファイル

XDG Base Directory Spec に従い、パーミッション 0600 で保存される。

- `$XDG_CONFIG_HOME/rururu/config.json` (環境変数が設定されていれば)
- `$HOME/.config/rururu/config.json` (デフォルト、macOS/Linux共通)

中身はプロファイル形式:

```json
{
  "default": "local",
  "profiles": {
    "local": { "endpoint": "https://fh.lvh.me/graphql", "app_password": "rururu_..." },
    "prod":  { "endpoint": "https://feedhub.herokuapp.com/graphql", "app_password": "rururu_..." }
  }
}
```

旧フォーマット(top-levelに `endpoint`/`app_password` がある形式)は読み込み時に自動で `default` プロファイルへマイグレーションされる。次回 `auth login` 等で書き込みが発生したタイミングで新フォーマットでファイルに反映される。
