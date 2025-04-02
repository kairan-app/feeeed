class OpenGraph
  attr_reader :url, :html, :title, :description, :image

  def initialize(url)
    @url = url
    fetch_and_parse
  end

  def fetch_and_parse
    return if @url.nil?

    @html = Nokogiri::HTML(Httpc.get(@url).force_encoding("UTF-8"))
    @title = @html.css("title").text

    metas = @html.css("meta")
    @description = metas.find { |m| m.attributes.find { |a| a[1].value == "og:description" } }&.attributes&.dig("content")&.value
    @image = metas.find { |m| m.attributes.find { |a| a[1].value == "og:image" } }&.attributes&.dig("content")&.value

    # og:imageに相対URLが指定されている場合は、@urlを基準に絶対URLに変換する
    @image = URI.join(@url, @image).to_s if @image&.start_with?("/")
  end
end
