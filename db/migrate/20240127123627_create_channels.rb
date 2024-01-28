class CreateChannels < ActiveRecord::Migration[7.1]
  def change
    create_table :channels do |t|
      t.string :title, null: false, limit: 100
      t.string :description, limit: 255
      t.string :site_link, null: false, limit: 255
      t.string :feed_link, null: false, limit: 255
      t.string :image_url, limit: 255

      t.timestamps
    end

    add_index :channels, :feed_link, unique: true
  end
end
