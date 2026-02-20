class Admin::ProxyRequiredDomainsController < AdminController
  def index
    @proxy_required_domains = ProxyRequiredDomain.order(created_at: :desc)
    @title = "Admin Proxy Required Domains"
  end

  def destroy
    @proxy_required_domain = ProxyRequiredDomain.find(params[:id])
    @proxy_required_domain.destroy!
    redirect_to admin_proxy_required_domains_path, notice: "#{@proxy_required_domain.domain} を削除しました"
  end
end
