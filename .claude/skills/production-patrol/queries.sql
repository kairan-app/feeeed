-- /production-patrol 用の読み取り専用クエリ
-- 実行: heroku pg:psql -a feedhub --file .claude/skills/production-patrol/queries.sql
SET default_transaction_read_only = on;

\echo '== 1. 失敗ジョブ (ジョブ × 例外クラス × 落ちた箇所)'
-- メッセージ本文は webhook の URL などの秘密を含みうるので出さず、backtrace のうち最初のアプリ内の行だけを出す
SELECT j.class_name,
       substring(e.error from '"exception_class":"([^"]+)"') AS exception_class,
       substring(e.error from '"(?:/app/)?((?:app|lib)/[^":]+:[0-9]+)') AS first_app_frame,
       count(*) AS n,
       min(e.created_at) AS first_at,
       max(e.created_at) AS last_at
FROM solid_queue_failed_executions e
JOIN solid_queue_jobs j ON j.id = e.job_id
GROUP BY 1, 2, 3
ORDER BY n DESC
LIMIT 20;

\echo '== 1b. 失敗ジョブの偏り (channel_id ごと)'
SELECT j.class_name,
       substring(j.arguments from '"channel_id":([0-9]+)') AS channel_id,
       count(*) AS n
FROM solid_queue_failed_executions e
JOIN solid_queue_jobs j ON j.id = e.job_id
WHERE j.arguments LIKE '%"channel_id":%'
GROUP BY 1, 2
ORDER BY n DESC
LIMIT 10;

\echo '== 2. 止まったチャンネル (停止中を除き、チェック間隔の3倍かつ24時間以上チェックされていない)'
SELECT count(*) AS stale_channels
FROM channels c
WHERE NOT EXISTS (SELECT 1 FROM channel_stoppers s WHERE s.channel_id = c.id)
  AND (c.last_items_checked_at IS NULL
       OR c.last_items_checked_at < NOW() - make_interval(hours => GREATEST(c.check_interval_hours * 3, 24)));

SELECT c.id, c.check_interval_hours, c.last_items_checked_at
FROM channels c
WHERE NOT EXISTS (SELECT 1 FROM channel_stoppers s WHERE s.channel_id = c.id)
  AND (c.last_items_checked_at IS NULL
       OR c.last_items_checked_at < NOW() - make_interval(hours => GREATEST(c.check_interval_hours * 3, 24)))
ORDER BY c.last_items_checked_at NULLS FIRST
LIMIT 20;

\echo '== 3. キューの滞留'
SELECT 'ready' AS kind, count(*) AS n, min(created_at) AS oldest FROM solid_queue_ready_executions
UNION ALL SELECT 'scheduled', count(*), min(scheduled_at) FROM solid_queue_scheduled_executions
UNION ALL SELECT 'claimed', count(*), min(created_at) FROM solid_queue_claimed_executions
UNION ALL SELECT 'blocked', count(*), min(created_at) FROM solid_queue_blocked_executions;

\echo '== 3b. ワーカープロセスのheartbeat'
SELECT kind, hostname, last_heartbeat_at, NOW() - last_heartbeat_at AS since
FROM solid_queue_processes
ORDER BY kind;

\echo '== 3c. DB接続数 (Heroku Postgres essential-1 の上限は20。この巡回自身の接続も1つ含む)'
SELECT count(*) AS total FROM pg_stat_activity WHERE datname = current_database();

SELECT coalesce(nullif(application_name, ''), '(なし)') AS application_name,
       state,
       count(*) AS n
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY 1, 2
ORDER BY n DESC;

\echo '== 3d. recurringタスクの最終実行'
SELECT task_key, max(run_at) AS last_run_at, NOW() - max(run_at) AS since
FROM solid_queue_recurring_executions
GROUP BY 1
ORDER BY 1;
