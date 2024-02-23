class My::ReactionsController < MyController
  def index
    @reactions = current_user.reactions.eager_load(:item).order(id: :desc).page(params[:page])

    @title = "My Reactions"
  end
end
