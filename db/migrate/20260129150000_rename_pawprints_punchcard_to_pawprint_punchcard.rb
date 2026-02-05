class RenamePawprintsPunchcardToPawprintPunchcard < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE user_profile_widgets
      SET widget_type = 'pawprint_punchcard'
      WHERE widget_type = 'pawprints_punchcard'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE user_profile_widgets
      SET widget_type = 'pawprints_punchcard'
      WHERE widget_type = 'pawprint_punchcard'
    SQL
  end
end
