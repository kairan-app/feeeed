class My::PawprintsController < MyController
  def index
    @pawprints = current_user.pawprints.eager_load(:item).order(id: :desc).page(params[:page])

    @title = "My Pawprints"
  end
end
