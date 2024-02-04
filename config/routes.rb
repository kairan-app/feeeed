Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  if Rails.env.development?
    require "sidekiq/web"
    mount Sidekiq::Web => "/sidekiq"
  end

  post "channels", to: "channels#create"
  get "channels/:channel_id", to: "channels#show", as: "channel"

  root "welcome#index"
end
