# フィードの entry のうち、まだ保存していないものを判定する (ChannelItemsUpdaterJob の only_non_existing と同じ判定)。
#
# 読み取りだけで冪等な照会なので、意味としては GET が合う。ただ entry は1フィードで数千件・数百KBになり、URL に載せられない。
# 本来は RFC 10008 の QUERY メソッドが合うが、2026-10 時点で Puma 8.0.2 は QUERY を 501 で拒否し、
# Rails 8.1 もメソッドとして知らない (Cloudflare と Heroku のルーターは通す)。
# そのため POST で body に載せる。Puma と Rails が QUERY に対応したら移す候補
class Fetcher::GuidLookupsController < Fetcher::BaseController
  MAX_ENTRIES = 5_000
  SLICE = 1_000

  def create
    entries = json_body["entries"]
    raise InvalidBody unless entries.is_a?(Array) && entries.size <= MAX_ENTRIES && entries.all?(Hash)

    channel_id = params[:channel_id].to_i
    keys = entries.flat_map { [ _1["entry_id"], _1["url"] ] }.compact.uniq
    existing = keys.each_slice(SLICE).flat_map { Item.where(channel_id:, guid: _1).pluck(:guid) }.to_set

    render json: { new: entries.map { !existing.include?(_1["entry_id"]) && !existing.include?(_1["url"]) } }
  end
end
