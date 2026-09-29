module FeedFilters
  module PreParse
    # XML 文字列を「書き換えてよい部分」と「CDATA・コメント・処理命令・DOCTYPE」に分け、
    # 書き換えてよい部分だけをブロックで変換してつなぎ直す。
    # Rust 版 (fetcher/src/filters/segments.rs) と同じ正規表現を使う。
    module XmlSegments
      PROTECTED = /<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|<!DOCTYPE[^\[>]*(?:\[.*?\])?[ \t\r\n]*>/m

      def self.map_unprotected(xml)
        out = +""
        pos = 0
        xml.scan(PROTECTED) do
          match = Regexp.last_match
          out << yield(xml[pos...match.begin(0)])
          out << match[0]
          pos = match.end(0)
        end
        out << yield(xml[pos..])
        out
      end
    end
  end
end
