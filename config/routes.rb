Rails.application.routes.draw do
  get "/up" => "rails/health#show", as: :rails_health_check

  require "sidekiq/web"
  mount Sidekiq::Web => "/sidekiq"

  post   "/google_auth_callback",              to: "sessions#create"
  delete "/session",                           to: "sessions#destroy",     as: "session"
  get    "/channels",                          to: "channels#index"
  post   "/channels",                          to: "channels#create"
  get    "/channels/:channel_id",              to: "channels#show",        as: "channel"
  post   "/channels/:channel_id/ownership",    to: "ownerships#create",    as: "channel_ownership"
  delete "/channels/:channel_id/ownership",    to: "ownerships#destroy"
  post   "/channels/:channel_id/subscription", to: "subscriptions#create", as: "channel_subscription"
  delete "/channels/:channel_id/subscription", to: "subscriptions#destroy"
  get    "/items",                             to: "items#index"
  post   "/items/:item_id/pawprint",           to: "pawprints#create",     as: "item_pawprint"
  delete "/items/:item_id/pawprint",           to: "pawprints#destroy"
  get    "/pawprints",                         to: "pawprints#index"
  get    "/users",                             to: "users#index"
  get    "/@:user_name",                       to: "users#show",           as: "user", constraints: { user_name: /[^\/]+/ }
  get    "/my/inbox",                          to: "my/inbox#show",        as: "inbox"
  get    "/my/pawprints",                      to: "my/pawprints#index",   as: "my_pawprints"
  get    "/my/profile",                        to: "my/profile#show",      as: "my_profile"
  put    "/my/profile",                        to: "my/profile#update"

  root "welcome#index"
end
