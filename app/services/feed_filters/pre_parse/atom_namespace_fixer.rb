module FeedFilters
  module PreParse
    class AtomNamespaceFixer < Base
      # Atomフィードで間違った名前空間URLが使われている場合を検出
      def applicable?(xml_content, metadata = {})
        # Atomフィードで、httpsの名前空間が使われている場合
        xml_content.include?('xmlns="https://www.w3.org/2005/Atom"') ||
          xml_content.include?("xmlns='https://www.w3.org/2005/Atom'")
      end

      # 名前空間URLをhttpsからhttpに修正
      def apply(xml_content, metadata = {})
        return xml_content unless applicable?(xml_content, metadata)

        modified_xml = xml_content.dup
        original_namespace = nil

        # ダブルクォートの場合
        if modified_xml.include?('xmlns="https://www.w3.org/2005/Atom"')
          original_namespace = 'xmlns="https://www.w3.org/2005/Atom"'
          modified_xml.gsub!('xmlns="https://www.w3.org/2005/Atom"', 'xmlns="http://www.w3.org/2005/Atom"')
        end

        # シングルクォートの場合
        if modified_xml.include?("xmlns='https://www.w3.org/2005/Atom'")
          original_namespace = "xmlns='https://www.w3.org/2005/Atom'"
          modified_xml.gsub!("xmlns='https://www.w3.org/2005/Atom'", "xmlns='http://www.w3.org/2005/Atom'")
        end

        mark_as_applied!(
          fixed: "Atom namespace URL protocol",
          original_namespace: original_namespace,
          corrected_namespace: original_namespace&.gsub("https:", "http:")
        )

        Rails.logger.info "[AtomNamespaceFixer] Fixed Atom namespace from https to http"

        modified_xml
      end
    end
  end
end
