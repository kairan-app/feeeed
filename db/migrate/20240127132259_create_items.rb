class CreateItems < ActiveRecord::Migration[7.1]
  def change
    create_table :items do |t|
      t.references :channel, null: false, foreign_key: true
      t.string :guid, limit: 255, null: false
      t.string :title, limit: 100, null: false
      t.string :link, limit: 255, null: false
      t.string :image_url, limit: 255

      t.timestamps
    end

    add_index :items, [:channel_id, :guid], unique: true
  end
end
