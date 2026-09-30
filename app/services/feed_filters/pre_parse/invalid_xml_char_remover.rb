module FeedFilters
  module PreParse
    # XML 1.0 で使えない文字 (タブ・LF・CR 以外の制御文字、U+FFFE/U+FFFF) を取り除く。
    # libxml2 はこれらに出会うとそこで読むのをやめ、以降の entry が捨てられてしまう。
    class InvalidXmlCharRemover < Base
      # String#count / String#delete に渡す文字の範囲。正規表現で文書全体を走査すると、
      # 巨大なフィード (57MB など) で Regexp.timeout (1秒) を超えるため、正規表現を使わない (#825)
      INVALID_CHARS = "\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF"
      CHAR_REF = /&#(?:x([0-9A-Fa-f]+)|([0-9]+));/

      def self.xml_char?(code)
        code == 0x9 || code == 0xA || code == 0xD ||
          (0x20..0xD7FF).cover?(code) || (0xE000..0xFFFD).cover?(code) || (0x10000..0x10FFFF).cover?(code)
      end

      def applicable?(xml_content, metadata = {})
        xml_content.count(INVALID_CHARS) > 0 || xml_content.include?("&#")
      end

      def apply(xml_content, metadata = {})
        removed_refs = 0

        # 該当が無ければ delete による全体のコピーを避ける
        removed_chars = xml_content.count(INVALID_CHARS)
        without_chars = removed_chars > 0 ? xml_content.delete(INVALID_CHARS) : xml_content

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
