require "strscan"

module FeedFilters
  module PreParse
    # XML 文字列を「書き換えてよい部分」と「CDATA・コメント・処理命令・DOCTYPE」に分け、
    # 書き換えてよい部分だけをブロックで変換してつなぎ直す。
    # Rust 版 (fetcher/src/filters/segments.rs) と同じ正規表現を使う。
    # StringScanner で byte オフセットを直接追跡し、UTF-8 文字列での O(n²) 変換を回避する。
    module XmlSegments
      PROTECTED = /<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|<!DOCTYPE[^\[>]*(?:\[.*?\])?[ \t\r\n]*>/m

      def self.map_unprotected(xml)
        scanner = StringScanner.new(xml)
        out = +""
        unprotected_start_pos = 0

        while !scanner.eos?
          # scan_until だと「未保護部分+保護部分」全体をコピーした文字列が返ってきて
          # 巨大な入力でメモリを余計に使うので、位置だけを進めるskip_untilを使う
          advanced = scanner.skip_until(PROTECTED)

          if advanced
            # scanner.matched は保護部分のみ (小さい)
            protected_text = scanner.matched
            protected_start_pos = scanner.pos - protected_text.bytesize
            unprotected_length = protected_start_pos - unprotected_start_pos

            # Extract using byteslice (byte offsets, no O(n) character conversion)
            unprotected = xml.byteslice(unprotected_start_pos, unprotected_length)

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
