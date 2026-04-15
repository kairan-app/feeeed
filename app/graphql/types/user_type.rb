# frozen_string_literal: true

module Types
  class UserType < Types::BaseObject
    field :id, ID, null: false
    field :name, String, null: false
    field :email, String, null: true
    field :icon_url, String, null: true
    field :subscriptions, [ Types::SubscriptionType ], null: false

    def subscriptions
      object.subscriptions.includes(:channel)
    end
  end
end
