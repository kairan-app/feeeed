use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedFormat {
    ItunesRss,
    RssFeedburner,
    GoogleDocsAtom,
    AtomYoutube,
    AtomFeedburner,
    AtomGoogleAlerts,
    Atom,
    Rss,
    JsonFeed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChannelMeta {
    pub title: Option<String>,
    pub description: Option<String>,
    pub site_url: Option<String>,
    pub image_url: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct EntryData {
    pub summary: Option<String>,
    pub itunes_subtitle: Option<String>,
    pub enclosure_url: Option<String>,
    pub enclosure_type: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShapedEntry {
    pub guid: String,
    pub title: String,
    pub url: String,
    pub image_url: Option<String>,
    /// UTC, 秒精度の RFC3339 (例: "2026-09-24T01:00:00Z")
    pub published_at: String,
    pub data: EntryData,
    /// Rails なら OGP 画像を取りに行く entry で、まだ取っていないもの (影モードの比較から image_url を外す)
    #[serde(skip)]
    pub image_pending_ogp: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkipReason {
    NoGuid,
    NoUrl,
    ValidationFailed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Skipped {
    pub title: Option<String>,
    pub reason: SkipReason,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShapedFeed {
    pub format: FeedFormat,
    pub channel: Option<ChannelMeta>,
    pub applied_filters: Vec<String>,
    pub entries: Vec<ShapedEntry>,
    pub skipped: Vec<Skipped>,
}

impl ShapedFeed {
    pub fn normalize_order(&mut self) {
        self.entries
            .sort_by(|a, b| (&a.published_at, &a.guid).cmp(&(&b.published_at, &b.guid)));
        self.skipped.sort_by(|a, b| {
            let ra = serde_json::to_string(&a.reason).unwrap();
            let rb = serde_json::to_string(&b.reason).unwrap();
            (ra, a.title.clone().unwrap_or_default()).cmp(&(rb, b.title.clone().unwrap_or_default()))
        });
    }
}
