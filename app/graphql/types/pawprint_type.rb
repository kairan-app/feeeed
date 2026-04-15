# frozen_string_literal: true

module Types
  class PawprintType < Types::BaseObject
    field :id, ID, null: false
    field :memo, String, null: true
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false
    field :user, Types::UserType, null: false
    field :item, Types::ItemType, null: false
  end
end
