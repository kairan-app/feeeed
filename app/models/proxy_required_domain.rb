class ProxyRequiredDomain < ApplicationRecord
  validates :domain, presence: true, uniqueness: true

  after_create_commit :notify_created
  after_destroy_commit :notify_destroyed

  def self.required?(url)
    domain = URI.parse(url).host
    exists?(domain: domain)
  rescue URI::InvalidURIError
    false
  end

  def self.register!(url)
    domain = URI.parse(url).host
    find_or_create_by!(domain: domain)
  rescue URI::InvalidURIError
    nil
  end

  def self.recheck_all!
    find_each do |record|
      record.recheck!
    end
  end

  def recheck!
    url = "https://#{domain}/"
    response = Httpc.direct_get(url)

    if response.status.between?(200, 299)
      Rails.logger.info "[ProxyRequiredDomain] #{domain} is now directly accessible, removing"
      destroy!
    end
  rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
    Rails.logger.info "[ProxyRequiredDomain] #{domain} still blocked: #{e.class}"
  rescue StandardError => e
    Rails.logger.warn "[ProxyRequiredDomain] Error rechecking #{domain}: #{e.message}"
  end

  private

  def notify_created
    DiscoPosterJob.perform_later(
      content: "[ProxyRequiredDomain] Added: `#{domain}`",
      channel: :content_updates
    )
  end

  def notify_destroyed
    DiscoPosterJob.perform_later(
      content: "[ProxyRequiredDomain] Removed: `#{domain}`",
      channel: :content_updates
    )
  end
end
