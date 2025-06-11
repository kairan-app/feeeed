class Channels::BulkImportController < ApplicationController
  before_action :login_required

  def new
    # 入力フォーム表示
  end

  def create
    urls = extract_urls(params)

    if urls.empty?
      redirect_back(fallback_location: new_channels_bulk_import_path,
                    alert: "No URLs found")
      return
    end

    # 既存チャンネルと新規チャンネルに分類
    existing_urls, new_urls = Channel.classify_urls(urls)

    # 新規チャンネルのみ100件制限を適用
    processed_new_urls = new_urls.first(100)
    skipped_count = new_urls.size - processed_new_urls.size

    # ジョブをキューに追加（既存URLは全て処理、新規URLは100件まで）
    BulkChannelImportJob.perform_later(current_user.id, existing_urls, processed_new_urls, skipped_count)

    redirect_to root_path, notice: "Bulk feed import started. You will be notified by email when completed."
  end

  private

  def extract_urls(params)
    urls = []

    # OPMLファイルからURL抽出
    if params[:opml_file].present?
      urls += FeedUrlExtractor.extract(params[:opml_file])
    end

    # テキストからURL抽出
    if params[:urls].present?
      urls += FeedUrlExtractor.extract(params[:urls])
    end

    urls.uniq
  end
end
