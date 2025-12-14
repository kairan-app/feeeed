require "nokogiri"

module FeedFilters
  module PreParse
    # 特定のRSSタグ内に含まれるHTMLエンティティを実際の文字に変換するフィルタ
    #
    # 一部のフィードでは<copyright>や<generator>などのタグに&copy;等のHTMLエンティティが
    # 含まれており、Feedjira/SAXMachineが正しく処理できず、以降の<title>や<description>を
    # パースできなくなる問題がある。
    #
    # このフィルタはタグ自体は残したまま、タグ内のHTMLエンティティのみを実際の文字に変換する。
    # これにより、フィルタの適用有無で「問題のあるフィード」を判定できる。
    class HtmlEntityFixer < Base
      # HTMLエンティティが問題を起こす可能性のあるタグ
      # これらのタグはアプリケーションで使用しないが、タグ自体は残す
      TARGET_TAGS = %w[
        copyright
        generator
      ].freeze

      def applicable?(xml_content, metadata = {})
        # 対象タグ内にHTMLエンティティが含まれている場合のみ適用
        TARGET_TAGS.any? do |tag|
          # まずタグが存在するかを単純な文字列検索で高速にチェック
          next false unless xml_content.include?("<#{tag}")

          # タグが存在する場合のみ、タグ内容を抽出してHTMLエンティティをチェック
          # 注: [^<]* を使うことで、巨大なファイルでのバックトラッキングを防止
          # copyright/generatorタグは通常テキストのみなのでこれで十分
          xml_content.match?(/<#{tag}[^>]*>([^<]*)&[a-zA-Z]+;/)
        end
      end

      def apply(xml_content, metadata = {})
        doc = Nokogiri::XML(xml_content)
        fixed_tags = []

        TARGET_TAGS.each do |tag|
          elements = doc.xpath("//channel/#{tag}")
          elements.each do |element|
            original_xml = element.to_xml
            # HTMLエンティティをデコードして実際の文字に変換
            # Nokogiri::HTML::DocumentFragmentを使ってHTMLとしてパースし、textで変換
            decoded_text = Nokogiri::HTML::DocumentFragment.parse(element.inner_html).text
            element.content = decoded_text

            # 変更があった場合のみ記録
            if element.to_xml != original_xml
              fixed_tags << tag unless fixed_tags.include?(tag)
            end
          end
        end

        if fixed_tags.any?
          mark_as_applied!(
            fixed_tags: fixed_tags,
            reason: "HTML entities in tags converted to actual characters"
          )
        end

        doc.to_xml
      end
    end
  end
end
