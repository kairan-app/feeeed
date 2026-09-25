use serde::{Deserialize, Serialize};

use crate::model::EntryData;

#[derive(Debug, Deserialize)]
pub struct ShadowBatch {
    pub channels: Vec<ShadowChannel>,
    pub proxy_required_domains: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ShadowChannel {
    pub channel_id: i64,
    pub feed_url: String,
    pub site_url: Option<String>,
    pub use_proxy: bool,
    pub stored: StoredChannel,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StoredChannel {
    pub title: String,
    pub description: Option<String>,
    pub site_url: Option<String>,
    pub image_url: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct NewGuidQuery {
    pub entry_id: Option<String>,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StoredItem {
    pub guid: String,
    pub title: String,
    pub url: String,
    pub image_url: Option<String>,
    pub published_at: String,
    /// Rails がこの item を保存した時刻 (UTC、`...Z`)。古い dispatcher は返さないので省略可
    #[serde(default)]
    pub created_at: Option<String>,
    pub data: EntryData,
}

pub struct DispatcherClient {
    base_url: String,
    token: String,
    client: reqwest::Client,
}

impl DispatcherClient {
    pub fn new(base_url: &str, token: &str) -> anyhow::Result<Self> {
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            token: token.to_string(),
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()?,
        })
    }

    pub async fn shadow_channels(
        &self,
        max: u32,
        order: &str,
        scope: &str,
    ) -> anyhow::Result<ShadowBatch> {
        Ok(self
            .client
            .get(format!("{}/shadow/channels", self.base_url))
            .query(&[
                ("max", max.to_string()),
                ("order", order.to_string()),
                ("scope", scope.to_string()),
            ])
            .bearer_auth(&self.token)
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
            .post(format!("{}/channels/{channel_id}/new-guids", self.base_url))
            .bearer_auth(&self.token)
            .json(&serde_json::json!({ "entries": entries }))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        Ok(res.new)
    }

    pub async fn stored_items(
        &self,
        channel_id: i64,
        guids: &[String],
    ) -> anyhow::Result<Vec<StoredItem>> {
        #[derive(Deserialize)]
        struct Res {
            items: Vec<StoredItem>,
        }
        let res: Res = self
            .client
            .post(format!(
                "{}/shadow/channels/{channel_id}/items",
                self.base_url
            ))
            .bearer_auth(&self.token)
            .json(&serde_json::json!({ "guids": guids }))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        Ok(res.items)
    }
}
