class Fetcher::LeasesController < Fetcher::BaseController
  MAX_PER_REQUEST = 32

  def create
    max = json_body["max"]
    raise InvalidBody unless max.is_a?(Integer) && max.between?(1, MAX_PER_REQUEST)

    leases = ChannelLease.grant!(worker_name:, max:, rollout_percent: FetcherRollout.percent)
    proxy_domains = ProxyRequiredDomain.pluck(:domain).map(&:downcase).uniq.sort

    render json: {
      leases: leases.map { |lease|
        { channel_id: lease.channel_id, feed_url: lease.channel.feed_url,
          site_url: lease.channel.site_url, use_proxy: proxy_domains.include?(lease.host) }
      },
      proxy_required_domains: proxy_domains
    }
  end
end
