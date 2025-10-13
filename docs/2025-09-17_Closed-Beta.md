# Closed Beta実装ログ

## 実装完了項目

### ログイン・認証フロー
- ✅ `/login` ページを実装
  - すでに登録済みの方向けのセクション (Googleログイン)
  - 新規ユーザー向けのセクション (Closed Beta説明 + Googleログイン)
- ✅ ヘッダーの「Login」リンクを `/login` に変更
  - `_menu.html.erb` の `if logged_in?` の `else` に統合
  - パーシャルを使わず直接記述してシンプル化

### JoinRequest機能
- ✅ `JoinRequest` モデルを実装
  - カラム: `email`, `icon_url`, `comment`, `approved_by_id`, `approved_at`
  - スコープ: `pending`, `approved`
  - メソッド: `approve_by(user)`, `approved?`, `pending?`
- ✅ JoinRequestフォーム (`/join_requests/new`)
  - Google認証後にリクエスト送信
  - Discord通知 (`#admin` チャンネル)
- ✅ `approve_by` メソッド内で以下を実行:
  - ウェルカムメール送信
  - Discord通知 (`#admin` チャンネル)s

### 管理者機能
- ✅ `User#admin?` フラグを追加
- ✅ `AdminController` を実装
  - admin以外のアクセスは404を返す
- ✅ `/admin` ページを実装
  - Join RequestsとJobsへのリンク
- ✅ `/admin/join_requests` でリクエスト一覧を表示
- ✅ `/admin/join_requests/:id/approval` で承認処理
- ✅ ハンバーガーメニューにAdminリンクを追加 (admin権限者のみ表示)
- ✅ Mission Control Jobsを `/admin/jobs` に移動
  - `as: :admin_jobs` でパスヘルパーを生成
  - BASIC認証をやめて、Admin権限による認可へ

### 通知システム
- ✅ Discord通知の複数チャンネル対応
  - `:admin`, `:user_activities` など
  - `Disco` クラスを拡張
- ✅ 各種通知にリンクを追加 (Channel, ChannelGroupなど)

## ファイル構成

### Controllers
- `app/controllers/login_controller.rb` - ログインページ
- `app/controllers/admin_controller.rb` - 管理者ベースコントローラー (`admin#index` を含む)
- `app/controllers/admin/join_requests_controller.rb` - リクエスト一覧
- `app/controllers/admin/join_requests/approvals_controller.rb` - 承認処理
- `app/controllers/join_requests_controller.rb` - リクエスト送信

### Models
- `app/models/join_request.rb` - JoinRequestモデル
- `app/models/user.rb` - `admin` カラムを追加

### Views
- `app/views/login/show.html.erb` - ログインページ
- `app/views/admin/index.html.erb` - 管理トップページ
- `app/views/admin/join_requests/index.html.erb` - リクエスト一覧
- `app/views/layouts/_menu.html.erb` - Adminリンクを追加

### Jobs & Mailers
- `app/jobs/join_request_notifier_job.rb` - リクエスト通知
- `app/mailers/join_request_mailer.rb` - ウェルカムメール

### Routes
- `GET /login` → `login#show`
- `GET /admin` → `admin#index`
- `GET /admin/join_requests` → `admin/join_requests#index`
- `POST /admin/join_requests/:id/approval` → `admin/join_requests/approvals#create`
- `GET /admin/jobs` → MissionControl::Jobs::Engine

### CSS
- `app/assets/stylesheets/application.css` - `.login-link` クラスを追加 (旧 `.google-login`)

## 技術的な改善

### コードの整理
- パーシャルの削減 (`_login_link.html.erb` を `_menu.html.erb` に統合)
- ルーティングの整理 (DHH流に寄せる)
- クラス名・ファイル名の実態に合わせた命名

## その他の変更

- ✅ `/info` ページを削除
  - Closed Beta移行により不要になったため
