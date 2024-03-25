class MakeSiteUrlOnChannelsNotRequired < ActiveRecord::Migration[7.1]
  def change
    change_column_null :channels, :site_url, true
  end
end
