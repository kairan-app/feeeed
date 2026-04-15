# frozen_string_literal: true

module Types
  class ItemType < Types::BaseObject
    field :id, ID, null: false
    field :title, String, null: false
    field :url, String, null: false
    field :image_url, String, null: true
    field :published_at, GraphQL::Types::ISO8601DateTime, null: false
    field :channel, Types::ChannelType, null: false
  end
end
