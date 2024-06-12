class CreateChannelGroups < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_groups do |t|
      t.string :name, null: false, limit: 64

      t.timestamps
    end
  end
end
