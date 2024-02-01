class OpenGraph
  attr_reader :url, :html, :title, :description, :image

  def initialize(url)
    @url = url
    fetch_and_parse
  end

  def fetch_and_parse
    @html = Nokogiri::HTML(Faraday.get(@url).body)
    @title = @html.css("title").text
    @description = @html.css("meta[name='description']").first&.attributes&.dig("content")&.value
    @image = @html.css("meta[property='og:image']").first&.attributes&.dig("content")&.value
  end
end
