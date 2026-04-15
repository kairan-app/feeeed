# frozen_string_literal: true

module Types
  class SubscriptionType < Types::BaseObject
    graphql_name "FeedSubscription"

    field :id, ID, null: false
    field :created_at, GraphQL::Types::ISO8601DateTime, null: false
    field :channel, Types::ChannelType, null: false
  end
end
