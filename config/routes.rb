Rails.application.routes.draw do
  get "/up" => "rails/health#show", as: :rails_health_check

  if Rails.env.development?
    require "sidekiq/web"
    mount Sidekiq::Web => "/sidekiq"
  end

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
  get    "/@:user_name",                       to: "users#show",           as: "user", constraints: { user_name: /[^\/]+/ }

  root "welcome#index"
end
