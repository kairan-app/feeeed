Rails.application.routes.draw do
  get "/up" => "rails/health#show", as: :rails_health_check

  require "sidekiq/web"
  mount Sidekiq::Web => "/sidekiq"

  post   "/google_auth_callback",              to: "sessions#create"
  delete "/session",                           to: "sessions#destroy"
  get    "/channels",                          to: "channels#index"
  post   "/channels",                          to: "channels#create"
  get    "/channels/:channel_id",              to: "channels#show",                  as: "channel"
  post   "/channels/:channel_id/ownership",    to: "ownerships#create",              as: "channel_ownership"
  delete "/channels/:channel_id/ownership",    to: "ownerships#destroy"
  post   "/channels/:channel_id/subscription", to: "subscriptions#create",           as: "channel_subscription"
  delete "/channels/:channel_id/subscription", to: "subscriptions#destroy"
  get    "/items",                             to: "items#index"
  post   "/items/:item_id/pawprint",           to: "pawprints#create",               as: "item_pawprint"
  delete "/items/:item_id/pawprint",           to: "pawprints#destroy"
  post   "/items/:item_id/skip",               to: "item_skips#create",              as: "item_skip"
  delete "/items/:item_id/skip",               to: "item_skips#destroy"
  get    "/pawprints",                         to: "pawprints#index"
  post   "/notification_webhooks",             to: "notification_webhooks#create"
  delete "/notification_webhooks/:id",         to: "notification_webhooks#destroy",  as: "notification_webhook"
  get    "/users",                             to: "users#index"
  get    "/@:user_name",                       to: "users#show",                     as: "user", constraints: { user_name: /[^\/]+/ }
  get    "/my",                                to: "my#index"
  get    "/my/inbox",                          to: "my/inbox#show",                  as: "inbox"
  get    "/my/unreads",                        to: "my/unreads#show",                as: "unreads"
  get    "/my/pawprints",                      to: "my/pawprints#index"
  get    "/my/profile",                        to: "my/profile#show"
  put    "/my/profile",                        to: "my/profile#update"
  get    "/my/notification_webhooks",          to: "my/notification_webhooks#index"

  root "welcome#index"
end
