module FeedFilters
  module PreParse
    # 「金, 25 9月 2026 16:07:00 GMT」のように曜日と月を日本語にした日時を英語の表記に直す。
    # 日本からアクセスすると検索エンジンのフィードがこの形で返すことがあり、Ruby の DateTime.parse は
    # 10〜12月を読み違え (1 10月 → 9月10日)、1月は読めない。
    # Rust 版と同じ結果にするため、\d や \s ではなく [0-9] と [ \t\r\n] を使う。
    class LocalizedDateFixer < Base
      DATE_ELEMENT = /<(pubDate|lastBuildDate|dc:date)>([^<]*)</
      JA_DATE = /\A([ \t\r\n]*)(?:[日月火水木金土],[ \t\r\n]*)?([0-9]{1,2})[ \t\r\n]+([0-9]{1,2})月[ \t\r\n]+([0-9]{4}(?:[ \t\r\n].*)?)\z/m
      MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze

      def applicable?(xml_content, metadata = {})
        xml_content.include?("月")
      end

      def apply(xml_content, metadata = {})
        fixed_count = 0

        fixed = XmlSegments.map_unprotected(xml_content) do |text|
          text.gsub(DATE_ELEMENT) do |whole|
            tag = $1
            date = JA_DATE.match($2)
            month = date && date[3].to_i
            next whole unless date && (1..12).cover?(month)

            fixed_count += 1
            "<#{tag}>#{date[1]}#{date[2]} #{MONTHS[month - 1]} #{date[4]}<"
          end
        end

        return xml_content unless fixed_count > 0

        mark_as_applied!(fixed: fixed_count)
        fixed
      end
    end
  end
end
