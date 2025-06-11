class FeedUrlExtractor
  def self.extract(input)
    if input.is_a?(ActionDispatch::Http::UploadedFile)
      extract_from_opml(input)
    else
      extract_from_text(input)
    end
  end

  private

  def self.extract_from_text(text)
    return [] if text.blank?

    text.split(/\r?\n/)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
  end

  def self.extract_from_opml(file)
    require "nokogiri"

    content = file.read
    doc = Nokogiri::XML(content)

    # OPMLのoutline要素からxmlUrl属性を抽出
    outlines = doc.xpath("//outline[@xmlUrl]")
    urls = outlines.map { |outline| outline["xmlUrl"] }.compact.uniq

    urls
  rescue => e
    Rails.logger.error "OPML parsing error: #{e.message}"
    []
  end
end
