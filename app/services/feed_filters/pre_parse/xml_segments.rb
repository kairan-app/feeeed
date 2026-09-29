module FeedFilters
  module PreParse
    # XML 文字列を「書き換えてよい部分」と「CDATA・コメント・処理命令・DOCTYPE」に分け、
    # 書き換えてよい部分だけをブロックで変換してつなぎ直す。
    # Rust 版 (fetcher/src/filters/segments.rs) と同じ正規表現を使う。
    # StringScanner で byte オフセットを直接追跡し、UTF-8 文字列での O(n²) 変換を回避する。
    module XmlSegments
      PROTECTED = /<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|<!DOCTYPE[^\[>]*(?:\[.*?\])?[ \t\r\n]*>/m

      def self.map_unprotected(xml)
        require "strscan"

        scanner = StringScanner.new(xml)
        out = +""
        unprotected_start_pos = 0

        while !scanner.eos?
          pos_before_scan = scanner.pos
          scanned_text = scanner.scan_until(PROTECTED)

          if scanned_text
            # scanned_text contains both unprotected and protected parts
            # scanner.matched contains ONLY the protected part
            protected_matched = scanner.matched
            unprotected_length = scanned_text.bytesize - protected_matched.bytesize

            # Extract using byteslice (byte offsets, no O(n) character conversion)
            unprotected = xml.byteslice(unprotected_start_pos, unprotected_length)
            protected_text = xml.byteslice(unprotected_start_pos + unprotected_length, protected_matched.bytesize)

            out << yield(unprotected) << protected_text
            unprotected_start_pos = scanner.pos
          else
            # No more protected sections, process the rest
            rest_length = xml.bytesize - unprotected_start_pos
            rest = xml.byteslice(unprotected_start_pos, rest_length)
            out << yield(rest)
            break
          end
        end

        out
      end
    end
  end
end
