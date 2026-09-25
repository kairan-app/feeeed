# Rust製fetcherの正解データとして、Railsの取り込み処理が保存する結果をHashで返す。
# HTTP (フィード取得・OGP)・Sentry・sleepを一時的に差し替え、DBへの変更はロールバックする。
class FetcherGolden
  FORMATS = {
    "Feedjira::Parser::ITunesRSS" => "itunes_rss",
    "Feedjira::Parser::RSSFeedBurner" => "rss_feedburner",
    "Feedjira::Parser::GoogleDocsAtom" => "google_docs_atom",
    "Feedjira::Parser::AtomYoutube" => "atom_youtube",
    "Feedjira::Parser::AtomFeedBurner" => "atom_feedburner",
    "Feedjira::Parser::AtomGoogleAlerts" => "atom_google_alerts",
    "Feedjira::Parser::Atom" => "atom",
    "Feedjira::Parser::RSS" => "rss",
    "Feedjira::Parser::JSONFeed" => "json_feed"
  }.freeze

  DATA_KEYS = %w[summary itunes_subtitle enclosure_url enclosure_type].freeze
  NULL_OGP = Struct.new(:image, :description).new(nil, nil)

  def self.build(body:, feed_url:)
    new(body:, feed_url:).build
  end

  def initialize(body:, feed_url:)
    @body = body
    @feed_url = feed_url
    @skipped = []
  end

  def build
    result = nil
    with_overrides do
      ActiveRecord::Base.transaction(requires_new: true) do
        result = build_in_transaction
        raise ActiveRecord::Rollback
      end
    end
    result
  end

  private

  def build_in_transaction
    normalization = Channel.fetch_and_normalize_feed(@feed_url)
    feed = normalization[:feed]
    channel, channel_meta = save_channel(feed, normalization)
    channel.fetch_and_save_items(:all)

    {
      format: FORMATS.fetch(feed.class.name),
      channel: channel_meta,
      applied_filters: normalization[:applied_filters],
      entries: channel.items.reload.map { entry_json(_1) }.sort_by { [ _1[:published_at], _1[:guid] ] },
      skipped: @skipped.sort_by { [ _1[:reason], _1[:title].to_s ] }
    }
  end

  def save_channel(feed, normalization)
    parameters = Channel.build_from(feed, @feed_url)
    if parameters
      channel = Channel.new(parameters.merge(
        feed_url: @feed_url,
        applied_filters: normalization[:applied_filters],
        filter_details: normalization[:filter_details]
      ))
      return [ channel, channel.slice(:title, :description, :site_url, :image_url) ] if channel.save
    end

    placeholder = Channel.new(feed_url: @feed_url, title: "golden placeholder")
    placeholder.save!(validate: false)
    [ placeholder, nil ]
  end

  def entry_json(item)
    {
      guid: item.guid,
      title: item.title,
      url: item.url,
      image_url: item.image_url,
      published_at: item.published_at.utc.iso8601,
      data: DATA_KEYS.index_with { item.data&.dig(_1)&.to_s }
    }
  end

  def with_overrides(&block)
    body = @body
    feed_url = @feed_url
    skipped = @skipped

    overrides = [
      [ Httpc, :get_with_redirect_info, ->(_url) { { body: body.dup, final_url: feed_url, redirected: false } } ],
      [ OpenGraph, :new, ->(_url) { NULL_OGP } ],
      [ Sentry, :capture_exception, ->(*_args, **_opts) { nil } ],
      [ Sentry, :capture_message, lambda { |_message, **opts|
        extra = opts[:extra] || {}
        skipped << { title: extra[:item_title], reason: extra[:skip_reason] } if extra[:skip_reason]
        nil
      } ]
    ]

    override_singletons(overrides) do
      Channel.define_method(:sleep) { |*| nil }
      begin
        block.call
      ensure
        Channel.remove_method(:sleep)
      end
    end
  end

  def override_singletons(overrides, &block)
    return block.call if overrides.empty?

    (target, name, impl), *rest = overrides
    original = target.method(name)
    target.define_singleton_method(name, &impl)
    begin
      override_singletons(rest, &block)
    ensure
      target.singleton_class.remove_method(name)
      target.define_singleton_method(name, original) if original.owner == target.singleton_class
    end
  end
end
