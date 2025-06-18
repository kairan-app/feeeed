require Rails.root.join("lib", "bot_blocker")

Rails.application.config.middleware.use BotBlocker
