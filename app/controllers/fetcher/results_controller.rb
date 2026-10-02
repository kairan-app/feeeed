# fetcher (Rust) から取得結果を受け取って保存する。lease を持っていない・期限切れなら 409 を返し、何も書かない
class Fetcher::ResultsController < Fetcher::BaseController
  def create
    payload = json_body
    raise InvalidBody unless FetchResultApplier.valid_payload?(payload)

    channel_id = params[:channel_id].to_i
    return head :conflict unless ChannelLease.renew(channel_id:, worker_name:)

    applier = FetchResultApplier.new(channel: Channel.find(channel_id))
    entries = applier.apply_channel!(payload) ? payload["entries"] : []

    if entries.size > FetchResultApplier::ITEMS_IN_REQUEST_LIMIT
      # lease は FetchResultApplyJob が終わるまで残し、その間に同じチャンネルを貸し出さない
      FetchResultApplyJob.perform_later(channel_id:, worker_name:, entries:, latest_guids: payload["latest_guids"])
      return render json: { queued: entries.size }, status: :accepted
    end

    counts = applier.save_items!(entries, latest_guids: Array(payload["latest_guids"]))
    applier.finish!
    ChannelLease.release(channel_id:, worker_name:)
    render json: counts
  end
end
