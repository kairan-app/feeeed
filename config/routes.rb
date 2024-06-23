Rails.application.routes.draw do
  get "/up" => "rails/health#show", as: :rails_health_check

  require "sidekiq/web"
  mount Sidekiq::Web => "/sidekiq"

  if Rails.env.development?
    mount LetterOpenerWeb::Engine => "/letter_opener"
  end

  post   "/google_auth_callback",              to: "sessions#create"
  delete "/session",                           to: "sessions#destroy"
  get    "/channels/preview",                  to: "channels/preview#show",
                                               as: "channel_preview"
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
  put    "/channel_groups/:id",                to: "channel_groups#update"
  get    "/channel_groups/new",                to: "channel_groups#new",
                                               as: "new_channel_group"
  post   "/channel_groupings",                 to: "channel_groupings#create"
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
  get    "/my",                                to: "my#index"
  get    "/my/guides",                         to: "my/guides#show",
                                               as: "guides"
  get    "/my/inbox",                          to: "my/inbox#show",
                                               as: "inbox"
  get    "/my/unreads",                        to: "my/unreads#show",
                                               as: "unreads"
  get    "/my/pawprints",                      to: "my/pawprints#index"
  get    "/my/profile",                        to: "my/profile#show"
  put    "/my/profile",                        to: "my/profile#update"
  get    "/my/notification_settings",          to: "my/notification_settings#index"
  get    "/about",                             to: "about#index",
                                               as: "about"
  get    "/info",                              to: "info#index",
                                               as: "info"

  root "welcome#index"
end
