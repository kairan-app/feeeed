class ChangeImageUrlToTextForChannelsAndItems < ActiveRecord::Migration[8.0]
  NEW_URL_LIMIT = 4096
  OLD_URL_LIMIT = 2083

  def up
    change_column :channels, :feed_url, :string, limit: NEW_URL_LIMIT
    change_column :channels, :site_url, :string, limit: NEW_URL_LIMIT
    change_column :channels, :image_url, :string, limit: NEW_URL_LIMIT

    change_column :items, :url, :string, limit: NEW_URL_LIMIT
    change_column :items, :image_url, :string, limit: NEW_URL_LIMIT

    change_column :users, :icon_url, :string, limit: NEW_URL_LIMIT

    change_column :notification_webhooks, :url, :string, limit: NEW_URL_LIMIT
    change_column :channel_group_webhooks, :url, :string, limit: NEW_URL_LIMIT
  end

  def down
    change_column :channels, :feed_url, :string, limit: OLD_URL_LIMIT
    change_column :channels, :site_url, :string, limit: OLD_URL_LIMIT
    change_column :channels, :image_url, :string, limit: OLD_URL_LIMIT

    change_column :items, :url, :string, limit: OLD_URL_LIMIT
    change_column :items, :image_url, :string, limit: OLD_URL_LIMIT

    change_column :users, :icon_url, :string, limit: OLD_URL_LIMIT

    change_column :notification_webhooks, :url, :string, limit: OLD_URL_LIMIT
    change_column :channel_group_webhooks, :url, :string, limit: OLD_URL_LIMIT
  end
end
