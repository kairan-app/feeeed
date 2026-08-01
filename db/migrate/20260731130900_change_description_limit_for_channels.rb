class ChangeDescriptionLimitForChannels < ActiveRecord::Migration[8.1]
  NEW_DESCRIPTION_LIMIT = 1400
  OLD_DESCRIPTION_LIMIT = 1024

  def up
    change_column :channels, :description, :string, limit: NEW_DESCRIPTION_LIMIT
  end

  def down
    change_column :channels, :description, :string, limit: OLD_DESCRIPTION_LIMIT
  end
end
