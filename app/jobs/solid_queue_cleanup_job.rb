class SolidQueueCleanupJob < ApplicationJob
  queue_as :default

  # 保持期間の設定（環境変数で上書き可能）
  RETENTION_DAYS = ENV.fetch("SOLID_QUEUE_RETENTION_DAYS", 14).to_i
  FAILED_JOB_RETENTION_DAYS = ENV.fetch("SOLID_QUEUE_FAILED_JOB_RETENTION_DAYS", 28).to_i

  def perform
    Rails.logger.info "Starting Solid Queue cleanup (retention: #{RETENTION_DAYS} days, failed: #{FAILED_JOB_RETENTION_DAYS} days)"

    # 削除前の状態を記録
    initial_job_count = SolidQueue::Job.count
    initial_failed_count = SolidQueue::FailedExecution.count

    # 完了済みジョブの削除
    finished_jobs_deleted = cleanup_finished_jobs

    # 失敗したジョブの削除
    failed_jobs_deleted = cleanup_failed_jobs

    # 関連する孤立レコードの削除
    orphaned_records_deleted = cleanup_orphaned_records

    # VACUUMの実行（オプション）
    vacuum_tables if should_vacuum?

    # 削除後の状態を記録
    final_job_count = SolidQueue::Job.count
    final_failed_count = SolidQueue::FailedExecution.count

    Rails.logger.info "Solid Queue cleanup completed: " \
                      "finished_jobs=#{finished_jobs_deleted}, " \
                      "failed_jobs=#{failed_jobs_deleted}, " \
                      "orphaned_records=#{orphaned_records_deleted}, " \
                      "remaining_jobs=#{final_job_count} (was #{initial_job_count}), " \
                      "remaining_failed=#{final_failed_count} (was #{initial_failed_count})"
  end

  private

  def cleanup_finished_jobs
    cutoff_date = RETENTION_DAYS.days.ago
    deleted_count = 0

    SolidQueue::Job
      .where("finished_at < ?", cutoff_date)
      .in_batches(of: 1000) do |batch|
        deleted_count += batch.delete_all
      end

    deleted_count
  end

  def cleanup_failed_jobs
    # 失敗したジョブは別の保持期間を使用
    cutoff_date = FAILED_JOB_RETENTION_DAYS.days.ago

    deleted_count = 0

    # FailedExecutionを削除
    SolidQueue::FailedExecution
      .joins(:job)
      .where("solid_queue_jobs.created_at < ?", cutoff_date)
      .in_batches(of: 1000) do |batch|
        deleted_count += batch.delete_all
      end

    # 関連する未完了の古いジョブも削除
    SolidQueue::Job
      .where(finished_at: nil)
      .where("created_at < ?", cutoff_date)
      .in_batches(of: 1000) do |batch|
        batch.delete_all
      end

    deleted_count
  end

  def cleanup_orphaned_records
    # 孤立したレコードを削除
    deleted_count = 0

    # ジョブが存在しない実行レコードを削除
    deleted_count += SolidQueue::ClaimedExecution
      .where.not(job_id: SolidQueue::Job.select(:id))
      .delete_all

    deleted_count += SolidQueue::ReadyExecution
      .where.not(job_id: SolidQueue::Job.select(:id))
      .delete_all

    deleted_count
  end

  def should_vacuum?
    # 本番環境でのみ、かつ深夜の実行時のみVACUUMを実行
    Rails.env.production? && Time.current.hour.between?(2, 4)
  end

  def vacuum_tables
    Rails.logger.info "Running VACUUM ANALYZE on Solid Queue tables"

    ActiveRecord::Base.connection.execute("VACUUM ANALYZE solid_queue_jobs")
    ActiveRecord::Base.connection.execute("VACUUM ANALYZE solid_queue_failed_executions")
    ActiveRecord::Base.connection.execute("VACUUM ANALYZE solid_queue_claimed_executions")
    ActiveRecord::Base.connection.execute("VACUUM ANALYZE solid_queue_ready_executions")
  rescue => e
    Rails.logger.error "Failed to vacuum tables: #{e.message}"
  end
end
