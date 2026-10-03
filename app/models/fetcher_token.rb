# fetcher (Rust) のトークンを照合する。トークンはマシンごとに発行し、環境変数 FETCHER_TOKENS に
# {"ワーカー名": "トークンの SHA-256 (16進)"} の JSON で置く (平文のトークンはサーバに置かない)
module FetcherToken
  def self.worker_name_for(token)
    return nil if token.blank?

    digest = Digest::SHA256.hexdigest(token)
    table.find { |_name, expected| ActiveSupport::SecurityUtils.secure_compare(expected.to_s.downcase, digest) }&.first
  end

  def self.table
    parsed = JSON.parse(ENV.fetch("FETCHER_TOKENS", "{}"))
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    Rails.logger.error "[FetcherToken] FETCHER_TOKENS is not valid JSON"
    {}
  end
end
