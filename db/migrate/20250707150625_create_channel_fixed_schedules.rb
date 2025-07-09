class CreateChannelFixedSchedules < ActiveRecord::Migration[8.0]
  def change
    create_table :channel_fixed_schedules do |t|
      t.references :channel, null: false, foreign_key: true
      t.integer :day_of_week, null: false
      t.integer :hour, null: false
      t.timestamps

      t.index [ :day_of_week, :hour ]
      t.index [ :channel_id, :day_of_week, :hour ], unique: true, name: 'idx_channel_fixed_schedules_unique'
    end
  end
end
