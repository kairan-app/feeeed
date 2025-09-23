# Closed Betaを開始する

- `/closed_beta` みたいなページを新設して、ヘッダの「Googleでログイン」はそこへのリンクに変える
- `/closed_beta` ページには「許可制にしているよ」の説明を載せる、使ってみたかったら「リクエスト」してね
- 「リクエスト」ってのはどういうこと？
    - Google認証してもらって、そこで得られるメールアドレスを「リクエストがありました」ってことで保存する
    - リクエストがあったらDiscord #sugiboku に通知する
    - モデル名「JoinRequest」
      - email/icon_url/comment/approved_by/approved_at
- リクエスト一覧ページ `/admin/join_requests` をつくる
  - adminだけが閲覧できる
- adminがリクエストをApproveしたらSignupできるようになる
    - メールでお知らせもする「利用準備ができました！」
        - オンボーディング情報も入れよう (使い方とか、Discordサーバの情報とか)
- https://rururu.app/info 更新するとよさそう

## メモ

- User#admin? を判別できるようになったら、Mission controlのBASIC認証もこれに置き換えたい
  - `/jobs` を `/admin/jobs` に移しつつ、だと納まりがよさそう
