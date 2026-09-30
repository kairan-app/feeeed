require "strscan"

module FeedFilters
  module PreParse
    # XML 文字列を「書き換えてよい部分」と「CDATA・コメント・処理命令・DOCTYPE」に分け、
    # 書き換えてよい部分だけをブロックで変換してつなぎ直す。
    # 区切りの規則は PROTECTED 正規表現と同じで、Rust 版 (fetcher/src/filters/segments.rs) はこの正規表現を使う。
    #
    # Ruby では、次の区切りを PROTECTED で探すと、区切りの少ない巨大な文書で1回の検索が文書の最後まで走り、
    # Regexp.timeout (1秒) を超える (#825)。そこで入口 (<! と <?) と閉じ (]]> など) は文字列の検索で探し、
    # 正規表現は DOCTYPE をその位置で確かめるときだけ使う。位置はすべて byte 単位で扱う。
    module XmlSegments
      PROTECTED = /<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|<!DOCTYPE[^\[>]*(?:\[.*?\])?[ \t\r\n]*>/m
      DOCTYPE = /<!DOCTYPE[^\[>]*(?:\[.*?\])?[ \t\r\n]*>/m
      # PROTECTED の選択肢と同じ順番。入口と閉じの組
      DELIMITED = [ [ "<![CDATA[", "]]>" ], [ "<!--", "-->" ], [ "<?", "?>" ] ].freeze

      def self.map_unprotected(xml)
        out = +""
        pos = 0
        cursor = 0
        # 閉じが文書の残りに無いと分かった区切りは、以降も見つからないので探し直さない
        missing = {}
        # 次の <! と <? の位置。追い越したときだけ探し直す (毎回探すと、片方が無い文書で O(n²) になる)
        next_bang = xml.byteindex("<!", 0)
        next_question = xml.byteindex("<?", 0)

        while (start = [ next_bang, next_question ].compact.min)
          length = protected_length(xml, start, missing)
          if length
            out << yield(xml.byteslice(pos, start - pos)) << xml.byteslice(start, length)
            pos = start + length
            cursor = pos
          else
            cursor = start + 1
          end
          next_bang = xml.byteindex("<!", cursor) if next_bang && next_bang < cursor
          next_question = xml.byteindex("<?", cursor) if next_question && next_question < cursor
        end

        out << yield(xml.byteslice(pos, xml.bytesize - pos))
      end

      # start の位置から区切りが始まっていれば、その byte 数を返す。始まっていなければ nil
      def self.protected_length(xml, start, missing)
        DELIMITED.each do |opening, closing|
          next unless xml.byteslice(start, opening.bytesize) == opening
          next if missing[closing]

          stop = xml.byteindex(closing, start + opening.bytesize)
          if stop
            return stop + closing.bytesize - start
          else
            missing[closing] = true
          end
        end

        return nil unless xml.byteslice(start, 9) == "<!DOCTYPE"

        scanner = StringScanner.new(xml)
        scanner.pos = start
        scanner.match?(DOCTYPE)
      end

      private_class_method :protected_length
    end
  end
end
