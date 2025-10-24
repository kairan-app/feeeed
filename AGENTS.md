# Tips

- 開発コンテナに向けて実行するコマンドは`docker compose run --rm web`を使ってください
- `rails`コマンドは`docker compose run --rm web rails`を使ってください
- ただし、`grep` `find`といったコマンドはDocker内部じゃなくそのまま実行できます
- ファイルを作成・編集したら`docker compose run --rm web bundle exec rubocop -c .rubocop.yml`の結果を確認してください
- Development環境での動作確認にはDevTools MCPを積極的に使ってください
  - `/dev/login?user_id=1`のようにして任意のUserでログインできて便利です
- Herokuのアプリ名は`feedhub`です
- Sentryの`feeeed`orgに`feeeed`projectがあります
