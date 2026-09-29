module FeedFilters
  module PreParse
    # XML 1.0 で使えない文字 (タブ・LF・CR 以外の制御文字、U+FFFE/U+FFFF) を取り除く。
    # libxml2 はこれらに出会うとそこで読むのをやめ、以降の entry が捨てられてしまう。
    class InvalidXmlCharRemover < Base
      INVALID_CHAR = /[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/
      CHAR_REF = /&#(?:x([0-9A-Fa-f]+)|([0-9]+));/

      def self.xml_char?(code)
        code == 0x9 || code == 0xA || code == 0xD ||
          (0x20..0xD7FF).cover?(code) || (0xE000..0xFFFD).cover?(code) || (0x10000..0x10FFFF).cover?(code)
      end

      def applicable?(xml_content, metadata = {})
        xml_content.match?(INVALID_CHAR) || xml_content.include?("&#")
      end

      def apply(xml_content, metadata = {})
        removed_chars = 0
        removed_refs = 0

        # match?でまず確認し、該当が無ければgsubによる全体コピーを避ける
        without_chars = if xml_content.match?(INVALID_CHAR)
          xml_content.gsub(INVALID_CHAR) do
            removed_chars += 1
            ""
          end
        else
          xml_content
        end

        fixed = if without_chars.include?("&#")
          XmlSegments.map_unprotected(without_chars) do |text|
            text.gsub(CHAR_REF) do |ref|
              code = $1 ? $1.to_i(16) : $2.to_i
              next ref if self.class.xml_char?(code)

              removed_refs += 1
              ""
            end
          end
        else
          without_chars
        end

        return xml_content unless removed_chars + removed_refs > 0

        mark_as_applied!(removed_chars: removed_chars, removed_refs: removed_refs)
        fixed
      end
    end
  end
end
