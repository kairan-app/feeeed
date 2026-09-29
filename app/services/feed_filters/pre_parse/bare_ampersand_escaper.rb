module FeedFilters
  module PreParse
    # 文字参照の形 (&name; / &#123; / &#x1F;) になっていない & を &amp; にする。
    # URL のクエリ (?a=1&b=2) をエスケープせずに書いたフィードで、libxml2 がそこで読むのをやめるのを防ぐ。
    class BareAmpersandEscaper < Base
      BARE_AMP = /&(?!(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#x[0-9A-Fa-f]+);)/

      def applicable?(xml_content, metadata = {})
        xml_content.include?("&")
      end

      def apply(xml_content, metadata = {})
        escaped = 0

        fixed = XmlSegments.map_unprotected(xml_content) do |text|
          text.gsub(BARE_AMP) do
            escaped += 1
            "&amp;"
          end
        end

        mark_as_applied!(escaped: escaped) if escaped > 0
        fixed
      end
    end
  end
end
