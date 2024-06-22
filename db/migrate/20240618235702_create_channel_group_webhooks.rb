class CreateChannelGroupWebhooks < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_group_webhooks do |t|
      t.references :channel_group, null: false, foreign_key: true
      t.string :url, null: false, limit: 2083
      t.datetime :last_notified_at

      t.timestamps
    end
  end
end
