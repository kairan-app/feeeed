require "uri"

module FeedFilters
  class RelativeUrlResolver < Base
    def applicable?(entry, channel)
      return false if entry.url.blank?

      # URLが相対パス（/で始まる）または、プロトコルが含まれていない場合
      !entry.url.start_with?("http://", "https://") || entry.url.start_with?("/")
    end

    def apply(entry, channel)
      return entry unless applicable?(entry, channel)

      original_url = entry.url
      base_url = extract_base_url(channel.feed_url)

      # 絶対URLに変換
      resolved_url = resolve_url(original_url, base_url)

      # entryのurlを更新（entryオブジェクトは直接変更できないので、新しい値を返す）
      entry.define_singleton_method(:url) { resolved_url }

      mark_as_applied!(
        original_url: original_url,
        resolved_url: resolved_url,
        base_url: base_url
      )

      Rails.logger.info "[RelativeUrlResolver] Converted '#{original_url}' to '#{resolved_url}'"

      entry
    end

    private

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
