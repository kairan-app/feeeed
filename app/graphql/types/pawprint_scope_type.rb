# frozen_string_literal: true

module Types
  class PawprintScopeType < Types::BaseEnum
    value "ALL", "全ユーザーの足あと", value: "all"
    value "MY", "自分の足あと", value: "my"
    value "TO_ME", "自分が所有するチャンネルへの足あと", value: "to_me"
  end
end
