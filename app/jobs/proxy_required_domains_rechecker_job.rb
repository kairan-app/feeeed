class ProxyRequiredDomainsRecheckerJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info "[ProxyRequiredDomainsRecheckerJob] Rechecking #{ProxyRequiredDomain.count} domains"
    ProxyRequiredDomain.recheck_all!
  end
end
