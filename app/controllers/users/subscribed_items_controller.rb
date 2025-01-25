class Users::SubscribedItemsController < ApplicationController
  def index
    @user = User.find_by(name: params[:user_name])
    @subscribed_items = Item.find_by_sql([ <<~SQL, @user.subscribed_channels.ids ])
      SELECT * FROM (
        SELECT items.*, ROW_NUMBER() OVER (PARTITION BY channel_id ORDER BY items.id DESC) AS row_number
        FROM items
        WHERE items.channel_id IN (?)
      ) AS numbered_items
      WHERE row_number <= 5
      ORDER BY id DESC
      LIMIT 60
    SQL

    respond_to do |format|
      format.atom
      format.json
    end
  end
end
