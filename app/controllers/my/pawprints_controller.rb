class My::PawprintsController < MyController
  def index
    search_params = params[:pawprint_q]&.to_unsafe_h || {}

    # 終了日が指定されている場合、その日の終わりまで含めるために翌日に調整
    # 元の値はフォーム表示用に保持
    @original_created_at_lteq = search_params[:created_at_lteq]
    if search_params[:created_at_lteq].present?
      end_date = Date.parse(search_params[:created_at_lteq]) + 1.day
      search_params[:created_at_lteq] = end_date.to_s
    end

    @pawprint_q = current_user.pawprints.eager_load(:item).ransack(search_params)
    @pawprints = @pawprint_q.result.order(id: :desc).page(params[:page])
    @title = "My Pawprints"
  end
end
