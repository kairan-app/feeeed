class AddFilterInfoToChannels < ActiveRecord::Migration[8.0]
  def change
    add_column :channels, :applied_filters, :json, default: []
    add_column :channels, :filter_details, :json, default: {}
  end
end
