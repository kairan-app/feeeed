class AddOwnerIdToChannelGroupsTable < ActiveRecord::Migration[7.1]
  def change
    add_reference :channel_groups, :owner, foreign_key: { to_table: :users }, null: false, default: 1
  end
end
