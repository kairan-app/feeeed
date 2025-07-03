class AddCheckIntervalToChannels < ActiveRecord::Migration[8.0]
  def change
    add_column :channels, :check_interval_hours, :integer, default: 1
    add_column :channels, :last_items_checked_at, :datetime

    add_index :channels, :last_items_checked_at
    add_index :channels, :check_interval_hours
  end
end
