class FeedNormalizer
  # Pre-parseフィルタ（XML文字列に対して適用）
  PRE_PARSE_FILTERS = [
    FeedFilters::PreParse::HtmlEntityFixer,
    FeedFilters::PreParse::AtomNamespaceFixer
    # 将来的に追加予定:
    # FeedFilters::PreParse::InvalidXmlFixer,
    # FeedFilters::PreParse::CharacterEncodingFixer
  ].freeze

  # Post-parseフィルタ（パース済みオブジェクトに対して適用）
  POST_PARSE_FILTERS = [
    FeedFilters::PostParse::RelativeUrlResolver
    # 将来的に追加予定:
    # FeedFilters::PostParse::DateNormalizer
  ].freeze

  def self.normalize_and_parse(raw_xml, feed_url)
    new(raw_xml, feed_url).normalize_and_parse
  end

  def initialize(raw_xml, feed_url)
    @raw_xml = raw_xml
    @feed_url = feed_url
    @applied_filters = []
    @filter_details = {}
  end

  def normalize_and_parse
    # Step 1: Pre-parseフィルタを適用（XML文字列レベル）
    normalized_xml = apply_pre_parse_filters(@raw_xml)

    # Step 2: Feedjiraでパース
    begin
      feed = Feedjira.parse(normalized_xml)
    rescue Feedjira::NoParserAvailable => e
      Rails.logger.error "[FeedNormalizer] Failed to parse feed even after normalization: #{e.message}"
      raise e
    end

    # Step 3: Post-parseフィルタを適用（オブジェクトレベル）
    normalized_feed = apply_post_parse_filters(feed)

    # 結果を返す
    {
      feed: normalized_feed,
      applied_filters: @applied_filters,
      filter_details: @filter_details
    }
  end

  private

  def apply_pre_parse_filters(xml_content)
    normalized_xml = xml_content

    PRE_PARSE_FILTERS.each do |filter_class|
      filter = filter_class.new
      metadata = { feed_url: @feed_url }

      if filter.applicable?(normalized_xml, metadata)
        Rails.logger.info "[FeedNormalizer] Applying pre-parse filter: #{filter_class.name}"
        normalized_xml = filter.apply(normalized_xml, metadata)

        if filter.applied
          @applied_filters << filter_class.name.demodulize
          @filter_details[filter_class.name.demodulize] = filter.details
        end
      end
    end

    normalized_xml
  end

  def apply_post_parse_filters(feed)
    normalized_feed = feed

    POST_PARSE_FILTERS.each do |filter_class|
      filter = filter_class.new
      metadata = { feed_url: @feed_url }

      if filter.applicable?(normalized_feed, metadata)
        Rails.logger.info "[FeedNormalizer] Applying post-parse filter: #{filter_class.name}"
        normalized_feed = filter.apply(normalized_feed, metadata)

        if filter.applied
          @applied_filters << filter_class.name.demodulize
          @filter_details[filter_class.name.demodulize] = filter.details
        end
      end
    end

    normalized_feed
  end
end
