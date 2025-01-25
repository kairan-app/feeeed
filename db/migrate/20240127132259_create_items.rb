class CreateItems < ActiveRecord::Migration[7.1]
  def change
    create_table :items do |t|
      t.references :channel, null: false, foreign_key: true
      t.string :guid, limit: 256, null: false
      t.string :title, limit: 256, null: false
      t.string :url, limit: 2083, null: false
      t.string :image_url, limit: 2083
      t.datetime :published_at, null: false

      t.timestamps
    end

    add_index :items, [ :channel_id, :guid ], unique: true
    add_index :items, :published_at
  end
end
