class AddUserIdColumnToChannelGroupWebhooksTable < ActiveRecord::Migration[7.2]
  def change
    add_reference :channel_group_webhooks, :user, foreign_key: true, null: false, default: 1
  end
end
