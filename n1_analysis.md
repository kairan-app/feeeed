# WelcomeController#index N+1問題分析

## 概要
WelcomeController#indexアクションで複数のN+1クエリ問題が発生しています。

## 1. Pawprints セクション

### 問題箇所
- `app/views/pawprints/_blocks.html.erb`で以下の関連データにアクセス:
  - `pawprint.user` (line 3)
  - `pawprint.item` (line 4)
  - `pawprint.item.channel` (line 19, 20)

### 現在のクエリ
```ruby
@pawprints = Pawprint.order(id: :desc).limit(12)
```

### N+1の詳細
- 12個のPawprintごとに:
  - 1クエリ: user取得
  - 1クエリ: item取得
  - 1クエリ: item.channel取得
- 合計: 1 + 12 * 3 = 37クエリ

### 解決策
```ruby
@pawprints = Pawprint.
  includes(:user, item: :channel).
  order(id: :desc).
  limit(12)
```

## 2. Channel and Items セクション

### 問題箇所
- `app/views/channels/_with3items.html.erb`で以下の関連データにアクセス:
  - `channel.items.order(id: :desc).limit(3)` (line 15)

### 現在のクエリ
```ruby
@channel_and_items = Channel.
  joins(:items).
  select("channels.*, MAX(items.id) AS max_item_id").
  group("channels.id").
  order("max_item_id DESC").
  limit(12)
```

### N+1の詳細
- 12個のChannelごとに:
  - 1クエリ: items取得（最新3件）
- 合計: 1 + 12 = 13クエリ

### 解決策
```ruby
@channel_and_items = Channel.
  joins(:items).
  select("channels.*, MAX(items.id) AS max_item_id").
  group("channels.id").
  order("max_item_id DESC").
  limit(12).
  includes(:items)
```

ただし、includesではorder/limitが効かないため、別アプローチが必要。

## 3. Channels セクション

### 問題箇所
- `app/views/channels/_flex_cards.html.erb`で問題なし
- favicon_urlメソッドは関連クエリを発生させない（site_urlまたはitemsの1件目を使用）

### 現在のクエリ
```ruby
@channels = Channel.order(id: :desc).limit(12)
```

### N+1の詳細
なし（image_url_or_placeholderとfavicon_urlは追加クエリを発生させない）

## 4. Channel Groups セクション

### 問題箇所
- `app/views/channel_groups/_flex_cards.html.erb`で以下のメソッドを呼び出し:
  - `channel_group.channel_image_urls_in_today` (line 4)
    - 内部で`channel_image_urls`を呼び出し
    - `channels.where.not(image_url: nil).pluck(:image_url)`を実行

### 現在のクエリ
```ruby
@channel_groups = ChannelGroup.order(id: :desc).limit(12)
```

### N+1の詳細
- 12個のChannelGroupごとに:
  - 1クエリ: channels取得（image_urlがnilでないもの）
- 合計: 1 + 12 = 13クエリ

### 解決策
```ruby
@channel_groups = ChannelGroup.
  includes(:channels).
  order(id: :desc).
  limit(12)
```

## 推奨される修正

WelcomeControllerのindexアクションを以下のように修正:

```ruby
def index
  @pawprints = Pawprint.
    includes(:user, item: :channel).
    order(id: :desc).
    limit(12)

  # channel_and_itemsは特殊な処理が必要
  @channel_and_items = Channel.
    joins(:items).
    select("channels.*, MAX(items.id) AS max_item_id").
    group("channels.id").
    order("max_item_id DESC").
    limit(12)

  # 各チャンネルの最新3アイテムを事前にロード
  channel_ids = @channel_and_items.map(&:id)
  items_by_channel = Item.
    where(channel_id: channel_ids).
    order(id: :desc).
    group_by(&:channel_id)

  @channel_and_items.each do |channel|
    channel.define_singleton_method(:recent_items) do
      @recent_items ||= (items_by_channel[id] || []).first(3)
    end
  end

  @channels = Channel.
    order(id: :desc).
    limit(12)

  @channel_groups = ChannelGroup.
    includes(:channels).
    order(id: :desc).
    limit(12)

  @title = "Enjoy feeds!"
end
```

ビューも対応する修正が必要:
- `app/views/channels/_with3items.html.erb`の15行目を以下に変更:
  ```erb
  <% channel.recent_items.each do |item| %>
  ```
