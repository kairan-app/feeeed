//! 本番の常駐モード。空いた枠の数だけ Rails から貸し出しを受け、1チャンネルずつ処理して結果を送る。
//! shutdown が来たら新しい貸し出しを止め、処理中のチャンネルを (持ち時間の範囲で) 終えてから戻る

use std::collections::HashSet;
use std::future::Future;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::task::JoinSet;

use crate::api_client::{ApiClient, Delivery, Lease};
use crate::http::{HttpClient, HttpConfig};
use crate::pipeline::process_lease;
use crate::result::ResultPayload;

pub struct RunOptions {
    pub api_url: String,
    pub token: String,
    pub concurrency: usize,
    /// 処理中のチャンネルが無いのに頼んだ数より少なかったとき・貸し出しに失敗したときに待つ時間
    pub idle_wait: Duration,
    /// 頼んだ数より少なかったが、処理中のチャンネルがあるときに待つ時間。
    /// 同じホストは同時に1つしか貸し出されないので、idle_wait だけ待つと、残りの多いホストの処理が詰まる
    pub busy_wait: Duration,
    /// 1チャンネルの持ち時間 (lease の期限 10分より短くする)
    pub deadline: Duration,
    pub result_retry_base: Duration,
    pub http: HttpConfig,
}

async fn handle(
    lease: Lease,
    http: Arc<HttpClient>,
    api: Arc<ApiClient>,
    proxy_domains: Arc<HashSet<String>>,
    deadline: Duration,
) {
    let channel_id = lease.channel_id;
    // 持ち時間の 3/5 を過ぎたら記事の OGP は取らない (取得・照会にかかった時間も含めて数え、残りは余裕として残す)
    let ogp_deadline = Instant::now() + deadline * 3 / 5;
    let payload = match tokio::time::timeout(
        deadline,
        process_lease(&lease, &http, &api, &proxy_domains, ogp_deadline),
    )
    .await
    {
        Ok(Ok(p)) => p,
        Ok(Err(e)) => {
            tracing::error!(channel_id, error = %format!("{e:#}"), "gave up processing, leaving the lease to expire");
            return;
        }
        Err(_) => ResultPayload::failed("deadline", format!("exceeded {}s", deadline.as_secs())),
    };
    let fetched = payload.fetched;
    let entries = payload.entries.len();
    match api.send_result(channel_id, &payload).await {
        Ok(Delivery::Accepted) => {
            tracing::info!(channel_id, fetched, entries, "result accepted");
        }
        Ok(Delivery::LeaseLost) => {
            tracing::warn!(channel_id, "lease was lost, result discarded");
        }
        Err(e) => {
            tracing::error!(channel_id, error = %format!("{e:#}"), "failed to send result, leaving the lease to expire");
        }
    }
}

pub async fn run(opts: RunOptions, shutdown: impl Future<Output = ()>) -> anyhow::Result<()> {
    // 0 だと空きが永遠に無く、空の JoinSet を待ち続けて空回りする
    anyhow::ensure!(opts.concurrency > 0, "concurrency must be at least 1");
    let api = Arc::new(
        ApiClient::new(&opts.api_url, &opts.token)?.with_retry_base(opts.result_retry_base),
    );
    let http = Arc::new(HttpClient::new(opts.http.clone())?);
    let mut tasks: JoinSet<()> = JoinSet::new();
    tokio::pin!(shutdown);

    loop {
        let free = opts.concurrency.saturating_sub(tasks.len());
        if free == 0 {
            tokio::select! {
                _ = &mut shutdown => break,
                res = tasks.join_next() => {
                    log_join(res);
                    continue;
                }
            }
        }

        let batch = tokio::select! {
            _ = &mut shutdown => break,
            b = api.leases(free) => b,
        };
        let wait = match batch {
            Ok(batch) => {
                tracing::info!(leased = batch.leases.len(), requested = free, "lease batch");
                // 頼んだ数より少なければ、今は他に取るべきチャンネルが無い。続けて頼まずに待つ
                let short = batch.leases.len() < free;
                let proxy_domains: Arc<HashSet<String>> =
                    Arc::new(batch.proxy_required_domains.into_iter().collect());
                for lease in batch.leases {
                    tracing::info!(channel_id = lease.channel_id, feed_url = %lease.feed_url, "leased");
                    tasks.spawn(handle(
                        lease,
                        http.clone(),
                        api.clone(),
                        proxy_domains.clone(),
                        opts.deadline,
                    ));
                }
                // 処理中のチャンネルがあれば、それが終わるとそのホストの次のチャンネルを貸し出せるので、短く待つ
                match (short, tasks.is_empty()) {
                    (false, _) => None,
                    (true, true) => Some(opts.idle_wait),
                    (true, false) => Some(opts.busy_wait),
                }
            }
            Err(e) => {
                tracing::error!(error = %format!("{e:#}"), "failed to lease channels");
                Some(opts.idle_wait)
            }
        };
        if let Some(wait) = wait {
            // 待っている間に終わったタスクも片付ける
            let sleep = tokio::time::sleep(wait);
            tokio::pin!(sleep);
            loop {
                tokio::select! {
                    _ = &mut shutdown => {
                        drain(&mut tasks).await;
                        return Ok(());
                    }
                    _ = &mut sleep => break,
                    res = tasks.join_next(), if !tasks.is_empty() => log_join(res),
                }
            }
        }
    }

    drain(&mut tasks).await;
    Ok(())
}

async fn drain(tasks: &mut JoinSet<()>) {
    tracing::info!(
        in_flight = tasks.len(),
        "shutting down, finishing in-flight channels"
    );
    while let Some(res) = tasks.join_next().await {
        log_join(Some(res));
    }
}

fn log_join(res: Option<Result<(), tokio::task::JoinError>>) {
    if let Some(Err(e)) = res {
        tracing::error!(error = %e, "channel task panicked");
    }
}
