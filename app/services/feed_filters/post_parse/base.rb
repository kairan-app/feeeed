module FeedFilters
  module PostParse
    class Base
      attr_reader :applied, :details

      def initialize(options = {})
        @applied = false
        @details = {}
        @options = options
      end

      # フィードオブジェクトが適用対象かどうかを判定
      # @param feed [Feedjira::Parser::RSS, Feedjira::Parser::Atom] パース済みフィードオブジェクト
      # @param metadata [Hash] 追加情報（feed_url等）
      # @return [Boolean]
      def applicable?(feed, metadata = {})
        raise NotImplementedError
      end

      # フィードオブジェクトを修正して返す
      # @param feed [Feedjira::Parser::RSS, Feedjira::Parser::Atom] パース済みフィードオブジェクト
      # @param metadata [Hash] 追加情報（feed_url等）
      # @return [Feedjira::Parser::RSS, Feedjira::Parser::Atom] 修正されたフィードオブジェクト
      def apply(feed, metadata = {})
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
