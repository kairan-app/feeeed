module FeedFilters
  module PreParse
    # 名前付きのエンティティ (&nbsp; など) を直すフィルタ。
    # XML で定義されているのは amp/lt/gt/quot/apos だけなので、それ以外の名前があると
    # libxml2 はそこで読むのをやめ、以降の entry が捨てられてしまう。
    # HTML の表にある名前は数値の文字参照に置き換え、表に無い名前は &amp;name; にして文字として残す。
    # 以前は channel の copyright と generator だけを対象にしていた。
    class HtmlEntityFixer < Base
      NAMED_REF = /&([A-Za-z][A-Za-z0-9]*);/
      PREDEFINED = %w[amp lt gt quot apos].freeze

      def applicable?(xml_content, metadata = {})
        # 独自のエンティティを宣言している文書は、宣言済みの名前を壊さないよう対象外にする
        Ampersands.match?(xml_content, NAMED_REF) && !xml_content.include?("<!ENTITY")
      end

      def apply(xml_content, metadata = {})
        replaced = 0
        unknown = 0

        fixed = XmlSegments.map_unprotected(xml_content) do |text|
          Ampersands.gsub(text, NAMED_REF) do |match|
            ref = match.matched
            name = match[1]
            chars = HtmlEntities::TABLE[name]
            if PREDEFINED.include?(name)
              ref
            elsif chars
              replaced += 1
              chars.codepoints.map { format("&#x%X;", _1) }.join
            else
              unknown += 1
              "&amp;#{name};"
            end
          end
        end

        return xml_content unless replaced + unknown > 0

        mark_as_applied!(replaced: replaced, unknown: unknown)
        fixed
      end
    end
  end
end
