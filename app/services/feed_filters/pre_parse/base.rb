module FeedFilters
  module PreParse
    class Base
      attr_reader :applied, :details

      def initialize(options = {})
        @applied = false
        @details = {}
        @options = options
      end

      # XMLが適用対象かどうかを判定
      # @param xml_content [String] 生のXML文字列
      # @param metadata [Hash] 追加情報（feed_url等）
      # @return [Boolean]
      def applicable?(xml_content, metadata = {})
        raise NotImplementedError
      end

      # XMLを修正して返す
      # @param xml_content [String] 生のXML文字列
      # @param metadata [Hash] 追加情報（feed_url等）
      # @return [String] 修正されたXML文字列
      def apply(xml_content, metadata = {})
        raise NotImplementedError
      end

      protected

      def mark_as_applied!(details = {})
        @applied = true
        @details = details
      end
    end
  end
end
