require "sidekiq/web"

Sidekiq::Web.use(Rack::Auth::Basic) do |user, password|
  [user, password] == [ENV["SIDEKIQ_WEB_BASIC_AUTH_USER"], ENV["SIDEKIQ_WEB_BASIC_AUTH_PASSWORD"]]
end
