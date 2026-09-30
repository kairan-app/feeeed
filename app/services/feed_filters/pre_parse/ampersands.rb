require "strscan"

module FeedFilters
  module PreParse
    # 文字列の & の位置ごとに、そこから pattern が合うかを確かめる。
    # 結果は text.gsub(pattern) や text.match?(pattern) と同じになる。
    #
    # 文書全体に正規表現をかけると、一致の少ない巨大な文書で1回の検索が文書の最後まで走り、
    # Regexp.timeout (1秒) を超える (#827)。そこで & は文字列の検索で探し、正規表現はその位置で確かめるときだけ使う。
    # pattern は & で始まり、途中に & を含まないものに限る。位置はすべて byte 単位で扱う
    # (String#index は文字単位で数えるので、ループで使うと O(n²) になる)。
    module Ampersands
      # 一致したところをブロックの返す文字列に置き換える。
      # ブロックには、一致した位置の StringScanner を渡す (matched や [1] で一致した中身を読める)
      def self.gsub(text, pattern)
        out = nil
        pos = 0
        cursor = 0
        scanner = StringScanner.new(text)

        while (at = text.byteindex("&", cursor))
          scanner.pos = at
          length = scanner.match?(pattern)
          if length
            (out ||= +"") << text.byteslice(pos, at - pos) << yield(scanner)
            pos = cursor = at + length
          else
            cursor = at + 1
          end
        end

        return text unless out

        out << text.byteslice(pos, text.bytesize - pos)
      end

      def self.match?(text, pattern)
        cursor = 0
        scanner = StringScanner.new(text)

        while (at = text.byteindex("&", cursor))
          scanner.pos = at
          return true if scanner.match?(pattern)

          cursor = at + 1
        end

        false
      end
    end
  end
end
