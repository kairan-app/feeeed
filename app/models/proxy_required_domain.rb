class ProxyRequiredDomain < ApplicationRecord
  validates :domain, presence: true, uniqueness: true

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
end
