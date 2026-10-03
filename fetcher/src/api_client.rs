//! Rails の /fetcher/* API のクライアント (本番の書き込み経路)。
//! 影モードの dispatcher_client とは別に持つ (影モードは dispatcher と一緒に廃止する)

use std::time::Duration;

use serde::Deserialize;

use crate::dispatcher_client::NewGuidQuery;
use crate::result::ResultPayload;

#[derive(Debug, Clone, Deserialize)]
pub struct Lease {
    pub channel_id: i64,
    pub feed_url: String,
    pub site_url: Option<String>,
    pub use_proxy: bool,
}

#[derive(Debug, Deserialize)]
pub struct LeaseBatch {
    pub leases: Vec<Lease>,
    pub proxy_required_domains: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Delivery {
    /// 保存された (200) か、保存がジョブに回された (202)
    Accepted,
    /// lease がもう自分のものではない (409)。結果は捨てる
    LeaseLost,
}

/// result の送り直しの回数 (最初の1回とは別に)
const MAX_RETRIES: u32 = 5;

pub struct ApiClient {
    base_url: String,
    token: String,
    client: reqwest::Client,
    retry_base: Duration,
}

impl ApiClient {
    pub fn new(base_url: &str, token: &str) -> anyhow::Result<Self> {
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            token: token.to_string(),
            // Rails はリクエストの中で保存まで行う (Heroku のルーターの上限は30秒)
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .build()?,
            retry_base: Duration::from_secs(2),
        })
    }

    pub fn with_retry_base(mut self, d: Duration) -> Self {
        self.retry_base = d;
        self
    }

    pub async fn leases(&self, max: usize) -> anyhow::Result<LeaseBatch> {
        Ok(self
            .client
            .post(format!("{}/fetcher/leases", self.base_url))
            .bearer_auth(&self.token)
            .json(&serde_json::json!({ "max": max }))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }

    pub async fn new_flags(
        &self,
        channel_id: i64,
        entries: &[NewGuidQuery],
    ) -> anyhow::Result<Vec<bool>> {
        #[derive(Deserialize)]
        struct Res {
            new: Vec<bool>,
        }
        let res: Res = self
            .client
            .post(format!(
                "{}/fetcher/channels/{channel_id}/guid_lookups",
                self.base_url
            ))
            .bearer_auth(&self.token)
            .json(&serde_json::json!({ "entries": entries }))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        anyhow::ensure!(
            res.new.len() == entries.len(),
            "guid_lookups returned {} flags for {} entries",
            res.new.len(),
            entries.len()
        );
        Ok(res.new)
    }

    pub async fn send_result(
        &self,
        channel_id: i64,
        payload: &ResultPayload,
    ) -> anyhow::Result<Delivery> {
        let url = format!("{}/fetcher/leases/{channel_id}/result", self.base_url);
        let mut attempt = 0;
        loop {
            let res = self
                .client
                .post(&url)
                .bearer_auth(&self.token)
                .json(payload)
                .send()
                .await;
            let retryable_error = match res {
                Ok(r) if r.status().is_success() => return Ok(Delivery::Accepted),
                Ok(r) if r.status() == reqwest::StatusCode::CONFLICT => {
                    return Ok(Delivery::LeaseLost);
                }
                Ok(r) if r.status().is_server_error() => anyhow::anyhow!("HTTP {}", r.status()),
                Ok(r) => anyhow::bail!("result rejected with HTTP {}", r.status()),
                Err(e) => e.into(),
            };
            if attempt >= MAX_RETRIES {
                return Err(
                    retryable_error.context(format!("gave up after {} attempts", attempt + 1))
                );
            }
            tracing::warn!(channel_id, attempt, error = %retryable_error, "failed to send result, retrying");
            tokio::time::sleep(self.retry_base * 2u32.pow(attempt)).await;
            attempt += 1;
        }
    }
}
