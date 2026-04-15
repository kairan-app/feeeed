# frozen_string_literal: true

module Types
  class ChannelType < Types::BaseObject
    field :id, ID, null: false
    field :title, String, null: false
    field :description, String, null: true
    field :feed_url, String, null: false
    field :site_url, String, null: true
    field :image_url, String, null: true
  end
end
