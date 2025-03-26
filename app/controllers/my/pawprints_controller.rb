class My::PawprintsController < MyController
  def index
    @pawprint_q = current_user.pawprints.eager_load(:item).ransack(params[:pawprint_q])
    @pawprints = @pawprint_q.result.order(id: :desc).page(params[:page])
    @title = "My Pawprints"
  end
end
