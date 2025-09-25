Rails.application.routes.draw do
  get "/up" => "rails/health#show", as: :rails_health_check

  if Rails.env.development?
    mount LetterOpenerWeb::Engine => "/letter_opener"
  end

  mount MissionControl::Jobs::Engine => "/admin/jobs"

  get    "/closed_beta",                       to: "closed_beta#show"

  get    "/join_requests/new",                 to: "join_requests#new",
                                               as: "new_join_request"
  post   "/join_requests",                      to: "join_requests#create",
                                               as: "join_requests"

  post   "/google_auth_callback",              to: "sessions#create"
  delete "/session",                           to: "sessions#destroy"
  get    "/channels/preview",                  to: "channels/preview#show",
                                               as: "channel_preview"
  get    "/channels/bulk_import/new",          to: "channels/bulk_import#new",
                                               as: "new_channels_bulk_import"
  post   "/channels/bulk_import",              to: "channels/bulk_import#create",
                                               as: "channels_bulk_import"
  get    "/channels",                          to: "channels#index"
  post   "/channels",                          to: "channels#create"
  get    "/channels/:channel_id",              to: "channels#show",
                                               as: "channel"
  post   "/channels/:channel_id/fetch",        to: "channels/fetch#create",
                                               as: "channel_fetch"
  post   "/channels/:channel_id/ownership",    to: "ownerships#create",
                                               as: "channel_ownership"
  delete "/channels/:channel_id/ownership",    to: "ownerships#destroy"
  post   "/channels/:channel_id/subscription", to: "subscriptions#create",
                                               as: "channel_subscription"
  delete "/channels/:channel_id/subscription", to: "subscriptions#destroy"
  post   "/channels/:channel_id/skip",         to: "channel_skips#create",
                                               as: "channel_skips"
  get    "/items",                             to: "items#index"
  post   "/items/:item_id/pawprint",           to: "pawprints#create",
                                               as: "item_pawprint"
  delete "/items/:item_id/pawprint",           to: "pawprints#destroy"
  post   "/items/:item_id/skip",               to: "item_skips#create",
                                               as: "item_skip"
  delete "/items/:item_id/skip",               to: "item_skips#destroy"
  get    "/channel_groups",                    to: "channel_groups#index"
  post   "/channel_groups",                    to: "channel_groups#create"
  get    "/channel_groups/:id",                to: "channel_groups#show",
                                               as: "channel_group",
                                               constraints: { id: /\d+/ }
  patch  "/channel_groups/:id",                to: "channel_groups#update"
  get    "/channel_groups/new",                to: "channel_groups#new",
                                               as: "new_channel_group"
  get    "/channel_groups/:id/edit",           to: "channel_groups#edit",
                                               as: "edit_channel_group"
  post   "/channel_groupings",                 to: "channel_groupings#create"
  delete "/channel_groupings/:id",             to: "channel_groupings#destroy",
                                               as: "channel_grouping"
  post   "/channel_groups/:id/membership",     to: "memberships#create",
                                               as: "channel_group_membership"
  delete "/channel_groups/:id/membership",     to: "memberships#destroy"
  get    "/pawprints",                         to: "pawprints#index"
  post   "/notification_webhooks",             to: "notification_webhooks#create"
  delete "/notification_webhooks/:id",         to: "notification_webhooks#destroy",
                                               as: "notification_webhook"
  post   "/notification_emails",               to: "notification_emails#create"
  delete "/notification_emails/:id",           to: "notification_emails#destroy",
                                               as: "notification_email"
  get    "/notification_emails/:token",        to: "notification_emails/verifications#create",
                                               as: "notification_email_verification"
  get    "/users",                             to: "users#index"
  get    "/@:user_name",                       to: "users#show",
                                               as: "user",
                                               constraints: { user_name: /[^\/]+/ }
  get    "/@:user_name/pawprints",             to: "users/pawprints#index",
                                               as: "user_pawprints",
                                               constraints: { user_name: /[^\/]+/ }
  get    "/@:user_name/subscribed_items",      to: "users/subscribed_items#index",
                                               as: "user_subscribed_items",
                                               constraints: { user_name: /[^\/]+/ }
  get    "/feeds/channels",                    to: "feeds/channels#index",
                                               defaults: { format: :atom }
  get    "/feeds/channel_groups",              to: "feeds/channel_groups#index",
                                               defaults: { format: :atom }
  get    "/my",                                to: "my#index"
  delete "/my",                                to: "my#destroy"
  get    "/my/guides",                         to: "my/guides#show",
                                               as: "guides"
  get    "/my/unreads",                        to: "my/unreads#show",
                                               as: "unreads"
  get    "/my/pawprints",                      to: "my/pawprints#index"
  get    "/my/owned_channels/pawprints",       to: "my/owned_channels/pawprints#index"
  get    "/my/profile",                        to: "my/profile#show"
  put    "/my/profile",                        to: "my/profile#update"
  get    "/my/notification_settings",          to: "my/notification_settings#index"
  get    "/my/graduation",                     to: "my/graduation#show"
  get    "/about",                             to: "about#index",
                                               as: "about"
  get    "/info",                              to: "info#index",
                                               as: "info"
  post   "/channel_group_webhooks",            to: "channel_group_webhooks#create"
  delete "/channel_group_webhooks/:id",        to: "channel_group_webhooks#destroy",
                                               as: "channel_group_webhook"
  get    "/terms",                             to: "legal#terms", as: :terms
  get    "/privacy",                           to: "legal#privacy", as: :privacy

  get    "/admin/join_requests",               to: "admin/join_requests#index",
                                               as: "admin_join_requests"
  post   "/admin/join_requests/:id/approval",  to: "admin/join_requests/approvals#create",
                                               as: "admin_join_request_approval"

  root "welcome#index"
end
