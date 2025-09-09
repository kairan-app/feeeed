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
        base_url = extract_base_url(feed_url)
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

      def has_relative_url?(url)
        return false if url.blank?
        # URLが相対パス（/で始まる）または、プロトコルが含まれていない場合
        url.start_with?("/") || !url.start_with?("http://", "https://")
      end

      def extract_base_url(feed_url)
        uri = URI.parse(feed_url)
        "#{uri.scheme}://#{uri.host}#{uri.port != uri.default_port ? ":#{uri.port}" : ''}"
      rescue URI::InvalidURIError
        # フォールバック: feed_urlが不正な場合
        feed_url.split("/")[0..2].join("/")
      end

      def resolve_url(url, base_url)
        # 既に絶対URLの場合はそのまま返す
        return url if url.start_with?("http://", "https://")

        # /で始まる絶対パスの場合
        if url.start_with?("/")
          "#{base_url}#{url}"
        else
          # 相対パスの場合（./やディレクトリ名で始まる）
          URI.join(base_url, url).to_s
        end
      rescue URI::InvalidURIError => e
        Rails.logger.error "[RelativeUrlResolver] Failed to resolve URL: #{url} with base: #{base_url} - #{e.message}"
        url # 変換に失敗した場合は元のURLを返す
      end
    end
  end
end
