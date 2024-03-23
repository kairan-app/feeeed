class MyController < ApplicationController
  before_action :login_required

  def index
    @title = "Settings"
  end
end
