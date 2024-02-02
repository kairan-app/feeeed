Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  post "channels", to: "channels#create"
  get "channels/:channel_id", to: "channels#show", as: "channel"

  root "welcome#index"
end
