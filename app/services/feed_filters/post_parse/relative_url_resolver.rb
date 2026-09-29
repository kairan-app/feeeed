require "uri"
require "ostruct"

module FeedFilters
  module PostParse
    class RelativeUrlResolver < Base
      # フィードまたはエントリーに相対URLが含まれているかチェック
      def applicable?(feed, metadata = {})
        # フィード自体のURLをチェック
        return true if has_relative_url?(feed.url)

        # 各エントリーのURLをチェック
        feed.entries.any? { |entry| has_relative_url?(entry.url) }
      end

      # フィードとエントリーの相対URLを絶対URLに変換
      def apply(feed, metadata = {})
        return feed unless applicable?(feed, metadata)

        feed_url = metadata[:feed_url]
        base_url = feed_url
        converted_urls = []

        # フィード自体のURLを修正
        if has_relative_url?(feed.url)
          original_url = feed.url
          resolved_url = resolve_url(feed.url, base_url)

          # OpenStructの場合は直接値を変更、それ以外はインスタンス変数を使用
          if feed.is_a?(OpenStruct)
            feed.url = resolved_url
          else
            feed.instance_variable_set(:@_normalized_url, resolved_url)
            feed.define_singleton_method(:url) do
              @_normalized_url || super()
            end
          end

          converted_urls << { from: original_url, to: resolved_url, target: "feed" }
        end

        # 各エントリーのURLを修正
        feed.entries.each do |entry|
          if has_relative_url?(entry.url)
            original_url = entry.url
            resolved_url = resolve_url(entry.url, base_url)

            # OpenStructの場合は直接値を変更、それ以外はインスタンス変数を使用
            if entry.is_a?(OpenStruct)
              entry.url = resolved_url
            else
              entry.instance_variable_set(:@_normalized_url, resolved_url)
              entry.define_singleton_method(:url) do
                @_normalized_url || super()
              end
            end

            converted_urls << { from: original_url, to: resolved_url, target: "entry" }
          end
        end

        # 詳細記録は最初の5個のサンプルのみに制限
        mark_as_applied!(
          base_url: base_url,
          converted_count: converted_urls.size,
          sample_urls: converted_urls.first(5),
          has_more: converted_urls.size > 5
        )

        Rails.logger.info "[RelativeUrlResolver] Converted #{converted_urls.size} relative URLs to absolute URLs"

        feed
      end

      private

      # 前後の空白・改行は取り除いてから判定する (<link> の中身が改行で始まるフィードがある)
      def has_relative_url?(url)
        return false if url.blank?

        !url.to_s.strip.start_with?("http://", "https://")
      end

      # フィードの URL を基準に RFC 3986 のとおり解決する
      def resolve_url(url, base_url)
        Addressable::URI.join(base_url, url.to_s.strip).to_s
      end
    end
  end
end
