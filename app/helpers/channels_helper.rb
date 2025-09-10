module ChannelsHelper
  def filter_name_in_japanese(filter_name)
    case filter_name
    when "AtomNamespaceFixer"
      "Atom名前空間修正"
    when "RelativeUrlResolver"
      "相対URL変換"
    when "EmptyFieldFiller"
      "空フィールド補完"
    when "InvalidXmlFixer"
      "不正XML修正"
    when "CharacterEncodingFixer"
      "文字エンコーディング修正"
    else
      filter_name
    end
  end

  def filter_description(filter_name)
    case filter_name
    when "AtomNamespaceFixer"
      "Atomフィードの名前空間URLをhttpsからhttpに修正しました"
    when "RelativeUrlResolver"
      "相対URLを絶対URLに変換しました"
    when "EmptyFieldFiller"
      "空のフィールドにデフォルト値を設定しました"
    when "InvalidXmlFixer"
      "不正なXML構造を修正しました"
    when "CharacterEncodingFixer"
      "文字エンコーディングの問題を修正しました"
    else
      "フィードの問題を自動修正しました"
    end
  end

  def render_filter_details(filter_name, details)
    return "" unless details

    case filter_name
    when "AtomNamespaceFixer"
      content_tag(:div, class: "text-sm text-gray-600 mt-1") do
        "修正前: #{details['original_namespace']}" if details["original_namespace"]
      end

    when "RelativeUrlResolver"
      content_tag(:div, class: "text-sm text-gray-600 mt-1") do
        if details["converted_count"]
          "#{details['converted_count']}個のURLを変換しました"
        end
      end

    when "EmptyFieldFiller"
      if details["filled_fields"]
        content_tag(:ul, class: "text-sm text-gray-600 mt-1") do
          details["filled_fields"].map do |field, value|
            content_tag(:li, "#{field}: #{value}")
          end.join.html_safe
        end
      end

    else
      content_tag(:div, class: "text-sm text-gray-600 mt-1") do
        details.to_json
      end
    end
  end
end
