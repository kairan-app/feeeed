class OpenGraph
  attr_reader :url, :html, :title, :description, :image

  def initialize(url)
    @url = url
    fetch_and_parse
  end

  def fetch_and_parse
    uri = URI.parse(@url)
    connection = Faraday.new(uri) do |c|
      c.use FaradayMiddleware::FollowRedirects
    end

    @html = Nokogiri::HTML(connection.get(uri.path).body)
    @title = @html.css("title").text

    metas = @html.css("meta")
    @description = metas.find { |m| m.attributes.find { |a| a[1].value == "og:description" } }&.attributes&.dig("content")&.value
    @image = metas.find { |m| m.attributes.find { |a| a[1].value == "og:image" } }&.attributes&.dig("content")&.value
  end
end
