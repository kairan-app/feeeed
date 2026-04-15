# frozen_string_literal: true

module Types
  class QueryType < Types::BaseObject
    field :viewer, Types::UserType, null: true, description: "認証済みユーザー。未認証ならnull。"
    def viewer
      context[:current_user]
    end
  end
end
