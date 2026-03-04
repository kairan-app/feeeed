module SidebarHelper
  def sidebar_submenu_item_classes(active)
    base = "px-1.5 py-1.5 rounded-md text-sm transition-colors flex items-center"
    active ? "#{base} bg-blue-50 text-blue-700" : "#{base} text-gray-600 hover:bg-gray-100"
  end

  def unreads_page_active?(tag_id: nil, group_id: nil)
    return false unless request.path == unreads_path

    if tag_id
      params[:subscription_tag_id].to_s == tag_id.to_s
    elsif group_id
      params[:channel_group_id].to_s == group_id.to_s
    else
      params[:subscription_tag_id].blank? && params[:channel_group_id].blank?
    end
  end

  def pawprints_page_active?(scope: nil)
    return false unless current_page?(pawprints_path)

    if scope
      params[:scope] == scope
    else
      params[:scope].blank?
    end
  end

  def sidebar_subscription_tags
    @_sidebar_subscription_tags ||= current_user.subscription_tags.joins(:subscriptions).distinct.ordered
  end

  def sidebar_channel_groups
    @_sidebar_channel_groups ||= current_user.own_and_joined_channel_groups.order(id: :desc)
  end
end
