class ChannelGroup < ApplicationRecord
  belongs_to :owner, class_name: "User"
  has_many :channel_groupings, dependent: :destroy
  has_many :channels, through: :channel_groupings
  has_many :items, through: :channels
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :channel_group_webhooks, dependent: :destroy

  validates :name, presence: true, length: { maximum: 64 }

  # トップページ用のスコープ
  scope :recent_with_associations, -> {
    includes(:channels, :owner)
      .order(id: :desc)
  }

  def channel_image_urls
    channels.where.not(image_url: nil).pluck(:image_url)
  end

  def channel_image_urls_in_today
    generator = Random.new(Date.today.to_time.to_i)
    channel_image_urls.sample(4, random: generator)
  end

  def placeholder_url
    "https://placehold.jp/30/cccccc/ffffff/300x300.png?text=#{name}"
  end
end
