class AddPerformanceIndexesToTables < ActiveRecord::Migration[8.0]
  def change
    # トップページのパフォーマンス改善用インデックス

    # items.channel_idとitems.idの複合インデックス
    # WelcomeController#indexで各チャンネルの最新アイテムを効率的に取得
    add_index :items, [ :channel_id, :id ], order: { channel_id: :asc, id: :desc },
              name: "index_items_on_channel_id_and_id_desc",
              if_not_exists: true

    # pawprints.idの降順インデックス（まだない場合）
    # WelcomeController#indexで最新のpawprintsを効率的に取得
    add_index :pawprints, [ :id ], order: { id: :desc },
              name: "index_pawprints_on_id_desc",
              if_not_exists: true

    # channel_groups.idの降順インデックス（まだない場合）
    # WelcomeController#indexで最新のchannel_groupsを効率的に取得
    add_index :channel_groups, [ :id ], order: { id: :desc },
              name: "index_channel_groups_on_id_desc",
              if_not_exists: true

    # channels.idの降順インデックス（まだない場合）
    # WelcomeController#indexで最新のchannelsを効率的に取得
    add_index :channels, [ :id ], order: { id: :desc },
              name: "index_channels_on_id_desc",
              if_not_exists: true
  end
end
