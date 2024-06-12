class CreateChannelGroupings < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_groupings do |t|
      t.references :channel, null: false, foreign_key: true
      t.references :channel_group, null: false, foreign_key: true

      t.timestamps
    end

    add_index :channel_groupings, %i[channel_id channel_group_id], unique: true
  end
end
