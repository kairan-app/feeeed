class CreateChannels < ActiveRecord::Migration[7.1]
  def change
    create_table :channels do |t|
      t.string :title, null: false, limit: 256
      t.string :description, limit: 1024
      t.string :site_url, null: false, limit: 2083
      t.string :feed_url, null: false, limit: 2083
      t.string :image_url, limit: 2083

      t.timestamps
    end

    add_index :channels, :site_url
    add_index :channels, :feed_url, unique: true
  end
end
