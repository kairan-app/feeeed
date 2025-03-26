class Pawprint < ApplicationRecord
  belongs_to :user
  belongs_to :item

  validates :user_id, presence: true, uniqueness: { scope: :item_id }
  validates :item_id, presence: true, uniqueness: { scope: :user_id }
  validates :memo, length: { maximum: 300 }

  after_create_commit { PawprintCreationNotifierJob.perform_later(self.id) }

  class << self
    def ransackable_attributes(auth_object = nil)
      %w[memo]
    end

    def ransackable_associations(auth_object = nil)
      %w[item]
    end
  end

  def to_discord_embed
    channel = item.channel
    {
      author: { name: [ channel.title, URI.parse(item.url).host ].join(" | "), url: channel.site_url },
      title: item.title,
      description: memo.present? ? "💬 #{memo}" : nil,
      url: item.url,
      thumbnail: { url: item.image_url },
      timestamp: self.created_at.iso8601
    }
  end

  def to_slack_block
    channel = item.channel

    block = [
      {
        "type": "divider"
      },
      {
        "type": "context",
        "elements": [
          channel.image_url.present? ? { "type": "image", "image_url": channel.image_url, "alt_text": channel.title } : nil,
          {
            "type": "mrkdwn",
            "text": channel.site_url ? "<#{channel.site_url}|#{channel.title}>" : channel.title
          }
        ].compact
      },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: [
            "*<#{item.url}|#{item.title}>*",
            memo.present? ? "💬 #{memo}" : nil,
            self.created_at.strftime("%Y-%m-%d %H:%M")
          ].compact.join("\n")
        }
      }
    ]

    if item.image_url.present?
      block.last[:accessory] = {
        type: "image",
        image_url: item.image_url,
        alt_text: item.title
      }
    end

    block
  end
end
