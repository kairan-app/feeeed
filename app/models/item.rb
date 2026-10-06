class Item < ApplicationRecord
  include Stripable
  include EmptyStringsAreAlignedToNil
  include UrlHttpValidator

  # 深いページは OFFSET が大きくなって遅い。robots.txt を無視してページを順に辿るクローラーも来るので、ページ数に上限を設ける
  max_pages 100

  belongs_to :channel
  has_many :pawprints, dependent: :destroy
  has_many :pawed_users, through: :pawprints, source: :user
  has_many :item_skips, dependent: :destroy

  validates :channel_id, presence: true
  validates :guid, presence: true, length: { maximum: 2083 }, uniqueness: { scope: :channel_id }
  validates :title, presence: true, length: { maximum: 256 }
  validates :url, presence: true
  validates :published_at, presence: true
  validates_url_http_format_of :url, :image_url

  # image_tag は、スキームも / も無い文字列をアセットパイプラインのファイル名として探し、例外を出す (#830)
  DISPLAYABLE_IMAGE_URL = %r{\A(?:https?:)?//}i

  scope :published_before, ->(time) { where("published_at <= ?", time) }

  strip_before_save :title, :image_url
  empty_strings_are_aligned_to_nil :image_url
  before_validation :fill_blank_title
  before_validation { self.image_url = self.class.normalize_image_url(image_url) if image_url_changed? }

  class << self
    def ransackable_attributes(auth_object = nil)
      %w[title]
    end

    def ransackable_associations(auth_object = nil)
      %w[channel]
    end

    # 最初の http(s):// から後ろだけを残し、末尾の空白を取り除く。URL が無ければ nil (Item の保存を失敗させない)。
    # フィードの image には、先頭に U+FFFC (オブジェクト置換文字) や改行・空白が付いていることがある (#830)。
    # String#strip は U+FFFC を取り除かず、URI.regexp は文字列のどこかに URL があれば一致するので、そのまま保存されていた
    def normalize_image_url(value)
      value = value.to_s
      start = value.index(%r{https?://}i)
      return nil if start.nil?

      value[start..].sub(/[[:space:]]+\z/, "")
    end
  end

  def image_url_or_placeholder
    return image_url if image_url&.match?(DISPLAYABLE_IMAGE_URL)

    "https://placehold.jp/30/cccccc/ffffff/270x180.png?text=#{URI.encode_www_form_component(self.title)}"
  end

  def summary(length: 1000)
    text = self.data&.dig("itunes_subtitle") || self.data&.dig("summary")
    return nil if text.nil?

    sanitized_text = ActionView::Base.full_sanitizer.sanitize(text)
    sanitized_text.truncate(length, omission: "...")
  end

  def enclosure_type
    self.data&.dig("enclosure_type")
  end

  def enclosure_url
    self.data&.dig("enclosure_url")
  end

  def audio_enclosure_url
    return nil if enclosure_type.nil?
    return nil unless enclosure_type.start_with?("audio/")

    enclosure_url
  end

  def video_enclosure_url
    return nil if enclosure_type.nil?
    return nil unless enclosure_type.start_with?("video/")

    enclosure_url
  end

  def to_discord_embed
    {
      author: { name: [ channel.title, Addressable::URI.parse(self.url).host ].join(" | "), url: channel.site_url },
      title: self.title,
      url: self.url,
      thumbnail: { url: self.image_url },
      timestamp: self.published_at.iso8601
    }
  end

  def to_slack_block
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: "<#{url}|#{title}>\n#{published_at.strftime("%Y-%m-%d %H:%M")}"
      },
      accessory: {
        type: "image",
        image_url: image_url,
        alt_text: title
      }
    }
  end

  private

  def fill_blank_title
    self.title = "〓" if title.blank?
  end
end
