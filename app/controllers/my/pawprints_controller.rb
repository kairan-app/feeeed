class My::PawprintsController < MyController
  def index
    @q = current_user.pawprints.eager_load(:item).ransack(params[:q])
    @pawprints = @q.result.order(id: :desc).page(params[:page])
    @title = "My Pawprints"
  end
end
