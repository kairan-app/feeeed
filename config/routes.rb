Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  post "channels", to: "channels#create"

  root "welcome#index"
end
