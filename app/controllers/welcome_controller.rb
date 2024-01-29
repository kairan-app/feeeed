class WelcomeController < ApplicationController
  def index
    @channels = Channel.order(id: :desc).limit(25)
  end
end
