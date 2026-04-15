# frozen_string_literal: true

module Types
  class QueryType < Types::BaseObject
    field :viewer, Types::UserType, null: true, description: "認証済みユーザー。未認証ならnull。"
    def viewer
      context[:current_user]
    end

    field :pawprints, [ Types::PawprintType ], null: false, description: "足あとの一覧。id降順。" do
      argument :scope, Types::PawprintScopeType, required: false, default_value: "all"
      argument :first, Integer, required: false, default_value: 50
      argument :before, ID, required: false, description: "このIDより古い足あとを返す(キーセットページング用)。"
    end
    def pawprints(scope:, first:, before: nil)
      first = first.clamp(1, 100)
      user = context[:current_user]

      relation = case scope
      when "my"
        return [] unless user
        user.pawprints
      when "to_me"
        return [] unless user
        Pawprint
          .joins(item: :channel)
          .joins("INNER JOIN ownerships ON ownerships.channel_id = channels.id")
          .where(ownerships: { user_id: user.id })
      else
        Pawprint.all
      end

      relation = relation.where("pawprints.id < ?", before) if before.present?
      relation
        .includes(:user, item: :channel)
        .order(id: :desc)
        .limit(first)
    end

    field :unread_items, [ Types::ItemType ], null: false,
      description: "未読(自分のpawprint/skip無し)記事の一覧。id降順。" do
      argument :range_days, Integer, required: false, default_value: 3,
        description: "何日前までの記事を対象にするか。"
      argument :channel_group_id, ID, required: false,
        description: "指定したChannelGroupに属する記事に絞る。"
      argument :subscription_tag_id, ID, required: false,
        description: "指定したSubscriptionTagに属する記事に絞る(自分のタグのみ)。"
      argument :first, Integer, required: false, default_value: 50
      argument :before, ID, required: false, description: "このIDより古い記事を返す(キーセットページング用)。"
    end
    def unread_items(range_days:, first:, channel_group_id: nil, subscription_tag_id: nil, before: nil)
      user = context[:current_user]
      return [] unless user

      first = first.clamp(1, 100)
      range_days = range_days.clamp(1, 365)

      base = if channel_group_id.present?
        channel_group = ChannelGroup.find_by(id: channel_group_id)
        return [] unless channel_group
        channel_group.items
      elsif subscription_tag_id.present?
        tag = user.subscription_tags.find_by(id: subscription_tag_id)
        return [] unless tag
        Item.joins(channel: :subscriptions).where(subscriptions: { id: tag.subscriptions.select(:id) })
      else
        user.subscribed_items
      end

      relation = base
        .where("NOT EXISTS (SELECT 1 FROM pawprints WHERE pawprints.item_id = items.id AND pawprints.user_id = ?)", user.id)
        .where("NOT EXISTS (SELECT 1 FROM item_skips WHERE item_skips.item_id = items.id AND item_skips.user_id = ?)", user.id)
        .where("items.created_at > ?", range_days.days.ago)

      relation = relation.where("items.id < ?", before) if before.present?
      relation
        .includes(:channel)
        .order("items.id DESC")
        .limit(first)
    end
  end
end
