class Channels::BulkImportController < ApplicationController
  before_action :login_required

  def new
    # 入力フォーム表示
  end

  def create
    urls = extract_urls(params)

    if urls.empty?
      redirect_back(fallback_location: new_channels_bulk_import_path,
                    alert: "URLが見つかりませんでした")
      return
    end

    if urls.size > 100
      redirect_back(fallback_location: new_channels_bulk_import_path,
                    alert: "一度に登録できるのは100件までです")
      return
    end

    # ジョブをキューに追加
    BulkChannelImportJob.perform_later(current_user.id, urls)

    redirect_to my_path, notice: "フィードの一括登録を開始しました。完了後メールでお知らせします。"
  end

  private

  def extract_urls(params)
    if params[:opml_file].present?
      FeedUrlExtractor.extract(params[:opml_file])
    elsif params[:urls].present?
      FeedUrlExtractor.extract(params[:urls])
    else
      []
    end
  end
end
