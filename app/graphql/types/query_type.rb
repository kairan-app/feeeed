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
  end
end
