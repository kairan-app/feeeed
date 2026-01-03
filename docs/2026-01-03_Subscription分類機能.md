# Subscription分類機能

- 現状、SubscribeしたChannelの新着ItemはUnreadsページに一列になって並ぶ
- Subscriptionに分類の仕組みを導入することによって、Unreadsページにて「Aなものだけ見る」「続いてBを見る」といったモード切り替えを実現したい
- 現状、Unreadsページには「Subscription all」の右に「Channel Groups」が並ぶ
  - ここを拡張して「Subscription all (未分類)」「Subscription A」「Subscription B」と分類を並べたあとに、「Channel Groups」がくるようにしたい
- SubscriptionTag的なモデルを用意して、利用者がSubscriptionのひとつひとつに分類用のタグをつけられるようにすればよさそう
  - 管理のために /my/subscriptions 的なページを用意して、そこでポチポチとタグの付け替えをできるようになっているといいかも

---

## 現状の構造

### Subscriptionモデル
```ruby
# シンプルな中間テーブルで、分類情報を持たない
create_table :subscriptions do |t|
  t.references :user, null: false, foreign_key: true
  t.references :channel, null: false, foreign_key: true
  t.timestamps
end
add_index :subscriptions, [:user_id, :channel_id], unique: true
```

### Unreadsページのフィルタリング
- 現在は `channel_group_id` パラメータで Channel Group によるフィルタリングのみ
- `User#unread_items_grouped_by_channel` でアイテム取得

---

## 設計案

### 案A: SubscriptionTagモデルを新設（多対多）

```ruby
create_table :subscription_tags do |t|
  t.references :user, null: false, foreign_key: true
  t.string :name, null: false, limit: 32
  t.integer :position, null: false, default: 0
  t.timestamps
end
add_index :subscription_tags, [:user_id, :name], unique: true
add_index :subscription_tags, [:user_id, :position]

create_table :subscription_taggings do |t|
  t.references :subscription, null: false, foreign_key: true
  t.references :subscription_tag, null: false, foreign_key: true
  t.timestamps
end
add_index :subscription_taggings, [:subscription_id, :subscription_tag_id], unique: true
```

**メリット**:
- 1つのSubscriptionに複数タグを付与可能
- タグの並び順を制御可能
- 柔軟な分類が可能

**デメリット**:
- テーブルが2つ増える
- 複数タグ対応のUIが複雑になる可能性

---

### 案B: Subscriptionに直接tag_id追加（多対1）

```ruby
create_table :subscription_tags do |t|
  t.references :user, null: false, foreign_key: true
  t.string :name, null: false, limit: 32
  t.integer :position, null: false, default: 0
  t.timestamps
end
add_index :subscription_tags, [:user_id, :name], unique: true
add_index :subscription_tags, [:user_id, :position]

# subscriptions テーブルに追加
add_reference :subscriptions, :subscription_tag, foreign_key: true  # NULL許可
```

**メリット**:
- シンプルな構造
- クエリが単純
- UIもシンプルに

**デメリット**:
- 1つのSubscriptionに1タグのみ
- 将来的な拡張性が低い

---

### 案C: Subscriptionにtag文字列を直接追加

```ruby
# subscriptions テーブルに追加
add_column :subscriptions, :tag, :string, limit: 32  # NULL許可
```

**メリット**:
- 最もシンプル
- マイグレーション1つで済む

**デメリット**:
- タグ名の一覧管理ができない
- タグ名変更時に全Subscriptionを更新必要
- 表示順の制御ができない

---

### 採用: 案A（多対多）

理由:
- 1つのSubscriptionに複数タグを付与できる柔軟性が必要

---

## 詳細設計

### モデル

```ruby
# app/models/subscription_tag.rb
class SubscriptionTag < ApplicationRecord
  belongs_to :user
  has_many :subscription_taggings, dependent: :destroy
  has_many :subscriptions, through: :subscription_taggings

  validates :name, presence: true, length: { maximum: 32 }
  validates :name, uniqueness: { scope: :user_id }
  validates :position, presence: true

  scope :ordered, -> { order(:position) }
end
```

```ruby
# app/models/subscription_tagging.rb
class SubscriptionTagging < ApplicationRecord
  belongs_to :subscription
  belongs_to :subscription_tag

  validates :subscription_id, uniqueness: { scope: :subscription_tag_id }
end
```

```ruby
# app/models/subscription.rb
class Subscription < ApplicationRecord
  include ChannelUserRelation

  has_many :subscription_taggings, dependent: :destroy
  has_many :subscription_tags, through: :subscription_taggings
end
```

```ruby
# app/models/user.rb に追加
has_many :subscription_tags, dependent: :destroy
```

### マイグレーション

```ruby
create_table :subscription_tags do |t|
  t.references :user, null: false, foreign_key: true
  t.string :name, null: false, limit: 32
  t.integer :position, null: false, default: 0
  t.timestamps
end
add_index :subscription_tags, [:user_id, :name], unique: true
add_index :subscription_tags, [:user_id, :position]

create_table :subscription_taggings do |t|
  t.references :subscription, null: false, foreign_key: true
  t.references :subscription_tag, null: false, foreign_key: true
  t.timestamps
end
add_index :subscription_taggings, [:subscription_id, :subscription_tag_id], unique: true
```

### Unreadsページの拡張

**コントローラ変更** (`My::UnreadsController`):

```ruby
def show
  # 既存
  @channel_group = ChannelGroup.find_by(id: params[:channel_group_id])
  @channel_groups = current_user.own_and_joined_channel_groups.order(id: :desc)

  # 追加
  @subscription_tag = SubscriptionTag.find_by(id: params[:subscription_tag_id])
  @subscription_tags = current_user.subscription_tags.ordered

  # 変更: subscription_tag も渡す
  @channel_and_items = current_user.unread_items_grouped_by_channel(
    range_days: @range_days,
    channel_group: @channel_group,
    subscription_tag: @subscription_tag
  )

  @unreads_params = {
    range_days: @range_days,
    channel_group_id: @channel_group&.id,
    subscription_tag_id: @subscription_tag&.id
  }
end
```

**Userモデル変更** (`User#unread_items_grouped_by_channel`):

```ruby
def unread_items_grouped_by_channel(range_days: 7, channel_group: nil, subscription_tag: nil)
  items = if channel_group
    channel_group.items
  elsif subscription_tag
    # subscription_tag に紐づくチャンネルのアイテム（多対多）
    tagged_subscription_ids = SubscriptionTagging.where(subscription_tag: subscription_tag).select(:subscription_id)
    Item.where(channel_id: subscriptions.where(id: tagged_subscription_ids).select(:channel_id))
  elsif subscription_tag == :untagged
    # 未分類のみ（タグが1つも付いていない）
    tagged_subscription_ids = SubscriptionTagging.select(:subscription_id)
    Item.where(channel_id: subscriptions.where.not(id: tagged_subscription_ids).select(:channel_id))
  else
    subscribed_items
  end

  # 以下は既存のまま...
end
```

### UIの変更

**Unreadsページのタブ構成**:

```
[Subscription all] [Tag A] [Tag B] [未分類] | [Channel Group 1] [Channel Group 2]
     ↑                                            ↑
  Subscription分類タブ群                    Channel Group タブ群（既存）
```

---

## 管理ページ設計

### `/my/subscriptions` - Subscription一覧・タグ管理

**機能**:
1. 購読中チャンネルの一覧表示
2. 各Subscriptionにタグを設定（ドロップダウン or ラジオボタン）
3. タグの追加・編集・削除・並び替え

**ルーティング**:

```ruby
namespace :my do
  resources :subscriptions, only: [:index, :update]
  resources :subscription_tags, only: [:index, :create, :update, :destroy] do
    collection do
      patch :reorder
    end
  end
end
```

**画面イメージ**:

```
┌─────────────────────────────────────────────────────────┐
│ My Subscriptions                                         │
├─────────────────────────────────────────────────────────┤
│ Tags: [+ 新規タグ]                                       │
│   🏷️ Tech News  [編集] [削除]  ⬆️⬇️                       │
│   🏷️ 趣味       [編集] [削除]  ⬆️⬇️                       │
│   🏷️ 仕事関連   [編集] [削除]  ⬆️⬇️                       │
├─────────────────────────────────────────────────────────┤
│ Subscriptions (24)                                       │
│                                                          │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ Hacker News                                         │ │
│ │ Tag: [Tech News ▼]                                  │ │
│ └─────────────────────────────────────────────────────┘ │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ ゲーム情報サイト                                      │ │
│ │ Tag: [趣味 ▼]                                       │ │
│ └─────────────────────────────────────────────────────┘ │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ 会社ブログ                                           │ │
│ │ Tag: [未設定 ▼]                                     │ │
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

---

## 検討事項

1. **未分類の扱い**: 「Subscription all」は「全て」か「未分類のみ」か？
   - → 「全て」とする。「未分類」は別タブとして表示

2. **Channel Groupsとの併用**: タグとChannel Groupの両方でフィルタできるようにするか？
   - → 排他的（どちらか一方のみ選択可能）

3. **タグの上限数**: ユーザーあたりのタグ数に制限を設けるか？
   - → 設けない

4. **デフォルトタグ**: 新規Subscriptionのデフォルトタグは？
   - → `[]`（タグなし）

5. **タグ名の重複**: 同一ユーザー内でのタグ名重複を禁止するか？
   - → 許容しない（UNIQUE制約で担保）

---

## 実装済み

### データベース
- `subscription_tags` テーブル作成（案Aの多対多構造を採用）
- `subscription_taggings` 中間テーブル作成
- 各種インデックス設定済み

### モデル
- `SubscriptionTag` モデル
  - `before_validation :set_position_on_create` で作成時に自動position設定
  - `after_destroy :normalize_positions_after_destroy` で削除後にposition正規化
  - `move_up` / `move_down` メソッドで並び替え
- `SubscriptionTagging` 中間モデル
- `Subscription` モデルに `has_many :subscription_taggings, dependent: :destroy` 追加
- `User#unsubscribe` メソッドを修正（`dependent: :destroy` が発動するように）

### Unreadsページ (`/my/unreads`)
- Tags / Channel Groups のフィルタリングUI実装
- 「Tags (Manage)」ヘッダーでタグ管理ページへのリンク
- TagsとChannel Groupsは排他的選択（どちらか一方のみ）
- タグはSubscriptionが1件以上あるもののみ表示
- 選択状態のスタイリング（青色 `#3d8bcd`）

### Subscriptions管理ページ (`/my/subscriptions`)
- 購読中チャンネル一覧表示（Channel画像付き）
- タグ管理セクション
  - タグ追加フォーム
  - タグ一覧（position順で表示）
  - 各タグに編集（pencilアイコン）・削除（trashアイコン）ボタン
  - 上下矢印で並び替え
- 各Subscriptionにチェックボックス形式でタグ付け
  - Optimistic UI（クリック時に即座に背景色が変化）
  - Turbo Streamで非同期更新
  - `id: nil` でスクロール位置維持

### タグ編集ページ (`/my/subscription_tags/:id/edit`)
- タグ名変更フォーム

### Channel詳細ページのSubscribedボタン
- ドロップダウンメニュー化
  - タグ選択チェックボックス（Subscribed状態のとき）
  - 区切り線
  - Unsubscribeリンク（赤色）
- タグ変更時はTurbo Streamで非同期更新

### ナビゲーション
- ユーザーメニュー（右上アイコン）に「Subscriptions」リンク追加

### Stimulusコントローラ
- `dropdown_controller.js` - ドロップダウンメニューの開閉制御
- `auto_submit_controller.js` - チェックボックス変更時の自動送信 + Optimistic UI

### 削除したコード
- `My::SubscriptionTagsController#reorder` アクション（未使用だったため）
- 対応するルーティング
