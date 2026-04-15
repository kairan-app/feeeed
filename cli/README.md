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

### ログイン

Web側の `/my/app_passwords` で発行した App Password を手元に控えておく。

```sh
rururu auth login
# Endpoint [https://fh.lvh.me/graphql]: (Enterでデフォルト、必要なら上書き)
# App Password: (貼り付け、入力は画面に表示されない)
# Logged in as june29
```

### 自分の情報を見る

```sh
rururu whoami
# june29 <june29x@gmail.com>
```

### ログアウト

保存された App Password を削除する。API側でトークンを revoke したい場合は Web 画面から行う。

```sh
rururu auth logout
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

中身は `{ "endpoint": "...", "app_password": "rururu_..." }` のみ。
