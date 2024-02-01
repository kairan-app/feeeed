class ChannelsController < ApplicationController
  def create
    if Channel.add(params[:url])
      flash[:notice] = "Channel added successfully"
    else
      flash[:alert] = "Channel could not be added"
    end

    redirect_to root_path
  end
end
