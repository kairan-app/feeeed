class PawprintsController < ApplicationController
  before_action :login_required
  before_action :set_item, only: %i[create destroy]

  VALID_SCOPES = %w[all my to_me].freeze

  def index
    @scope = params[:scope].presence || "all"
    @scope = "all" unless VALID_SCOPES.include?(@scope)

    # Ransack検索パラメータの処理
    search_params = params[:pawprint_q]&.to_unsafe_h || {}

    # 終了日が指定されている場合、その日の終わりまで含めるために翌日に調整
    @original_created_at_lteq = search_params[:created_at_lteq]
    if search_params[:created_at_lteq].present?
      end_date = Date.parse(search_params[:created_at_lteq]) + 1.day
      search_params[:created_at_lteq] = end_date.to_s
    end

    base_query = pawprints_base_query(@scope)
    @pawprint_q = base_query.ransack(search_params)
    @pawprints = @pawprint_q.result.order(id: :desc).page(params[:page])

    @title = pawprints_title(@scope)
  end

  def create
    @pawprint = current_user.paw(@item, memo: params[:memo])
  end

  def destroy
    @prev_memo = params[:memo]
    current_user.unpaw(@item)
  end

  private

  def set_item
    @item = Item.find(params[:item_id])
  end

  def pawprints_base_query(scope)
    case scope
    when "my"
      current_user.pawprints.eager_load(:user, :item)
    when "to_me"
      Pawprint
        .joins(item: :channel)
        .joins("INNER JOIN ownerships ON ownerships.channel_id = channels.id")
        .where(ownerships: { user_id: current_user.id })
        .eager_load(:user, :item)
    else
      Pawprint.eager_load(:user, :item)
    end
  end

  def pawprints_title(scope)
    case scope
    when "my"
      "My Pawprints"
    when "to_me"
      "Pawprints to Me"
    else
      "Pawprints"
    end
  end
end
