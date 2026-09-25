use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use serde::Serialize;
use tokio::io::AsyncWriteExt;
use tokio::sync::{Mutex, Semaphore};

use crate::dispatcher_client::{
    DispatcherClient, NewGuidQuery, ShadowChannel, StoredChannel, StoredItem,
};
use crate::http::{HttpClient, HttpConfig};
use crate::model::{ChannelMeta, FeedFormat, ShapedEntry, Skipped};
use crate::shape;

const CHUNK: usize = 1000;

#[derive(Debug, Serialize)]
pub struct FieldDiff {
    pub field: &'static str,
    pub guid: Option<String>,
    pub rust: Option<String>,
    pub rails: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ChannelReport {
    pub channel_id: i64,
    pub feed_url: String,
    pub status: &'static str,
    pub error: Option<String>,
    pub format: Option<FeedFormat>,
    pub applied_filters: Vec<String>,
    pub entries_in_feed: usize,
    pub new_entries: usize,
    pub entries_compared: usize,
    pub skipped: Vec<Skipped>,
    pub diffs: Vec<FieldDiff>,
    pub elapsed_ms: u128,
}

pub struct ShadowOptions {
    pub api_url: String,
    pub token: String,
    pub max: u32,
    pub order: String,
    pub concurrency: usize,
    pub out: PathBuf,
    pub http: HttpConfig,
}

fn diff(
    field: &'static str,
    guid: Option<&str>,
    rust: Option<&str>,
    rails: Option<&str>,
) -> Option<FieldDiff> {
    (rust != rails).then(|| FieldDiff {
        field,
        guid: guid.map(str::to_string),
        rust: rust.map(str::to_string),
        rails: rails.map(str::to_string),
    })
}

pub fn compare_channel(
    stored: &StoredChannel,
    rust: Option<&ChannelMeta>,
    format: FeedFormat,
) -> Vec<FieldDiff> {
    let Some(meta) = rust else {
        return vec![FieldDiff {
            field: "channel",
            guid: None,
            rust: None,
            rails: Some(stored.title.clone()),
        }];
    };
    let mut out = Vec::new();
    out.extend(diff(
        "title",
        None,
        meta.title.as_deref(),
        Some(&stored.title),
    ));
    out.extend(diff(
        "site_url",
        None,
        meta.site_url.as_deref(),
        stored.site_url.as_deref(),
    ));
    if format != FeedFormat::AtomYoutube {
        out.extend(diff(
            "description",
            None,
            meta.description.as_deref(),
            stored.description.as_deref(),
        ));
    }
    if format == FeedFormat::ItunesRss {
        out.extend(diff(
            "image_url",
            None,
            meta.image_url.as_deref(),
            stored.image_url.as_deref(),
        ));
    }
    out
}

pub fn compare_entries(rust: &[ShapedEntry], stored: &[StoredItem]) -> Vec<FieldDiff> {
    let by_guid: HashMap<&str, &ShapedEntry> = rust.iter().map(|e| (e.guid.as_str(), e)).collect();
    let mut out = Vec::new();
    for s in stored {
        let Some(r) = by_guid.get(s.guid.as_str()) else {
            continue;
        };
        let g = Some(s.guid.as_str());
        out.extend(diff("title", g, Some(&r.title), Some(&s.title)));
        out.extend(diff("url", g, Some(&r.url), Some(&s.url)));
        out.extend(diff(
            "published_at",
            g,
            Some(&r.published_at),
            Some(&s.published_at),
        ));
        out.extend(diff(
            "summary",
            g,
            r.data.summary.as_deref(),
            s.data.summary.as_deref(),
        ));
        out.extend(diff(
            "itunes_subtitle",
            g,
            r.data.itunes_subtitle.as_deref(),
            s.data.itunes_subtitle.as_deref(),
        ));
        out.extend(diff(
            "enclosure_url",
            g,
            r.data.enclosure_url.as_deref(),
            s.data.enclosure_url.as_deref(),
        ));
        out.extend(diff(
            "enclosure_type",
            g,
            r.data.enclosure_type.as_deref(),
            s.data.enclosure_type.as_deref(),
        ));
        if !r.image_pending_ogp {
            out.extend(diff(
                "image_url",
                g,
                r.image_url.as_deref(),
                s.image_url.as_deref(),
            ));
        }
    }
    out
}

fn empty_report(
    ch: &ShadowChannel,
    status: &'static str,
    error: String,
    started: Instant,
) -> ChannelReport {
    ChannelReport {
        channel_id: ch.channel_id,
        feed_url: ch.feed_url.clone(),
        status,
        error: Some(error),
        format: None,
        applied_filters: vec![],
        entries_in_feed: 0,
        new_entries: 0,
        entries_compared: 0,
        skipped: vec![],
        diffs: vec![],
        elapsed_ms: started.elapsed().as_millis(),
    }
}

async fn process(
    ch: ShadowChannel,
    http: &HttpClient,
    api: &DispatcherClient,
) -> anyhow::Result<ChannelReport> {
    let started = Instant::now();
    let res = match http.get_feed(&ch.feed_url, ch.use_proxy).await {
        Ok(r) => r,
        Err(e) => {
            return Ok(empty_report(
                &ch,
                "fetch_error",
                format!("{}: {e}", e.kind()),
                started,
            ));
        }
    };
    let prepared = match crate::prepare(&res.body, &ch.feed_url) {
        Ok(p) => p,
        Err(e) => return Ok(empty_report(&ch, "parse_error", e.to_string(), started)),
    };
    let format = prepared.feed.format;
    let meta = shape::channel::channel_meta(&prepared.feed, &ch.feed_url, None);
    let site_url = meta
        .as_ref()
        .and_then(|m| m.site_url.clone())
        .or(ch.site_url.clone());
    let (drafts, mut skipped) = shape::entry::draft_entries(&prepared.feed, site_url.as_deref());
    let entries_in_feed = prepared.feed.entries.len();

    let guids_in_draft_order: Vec<String> = drafts.iter().map(|d| d.guid.clone()).collect();
    let queries: Vec<NewGuidQuery> = drafts
        .iter()
        .map(|d| NewGuidQuery {
            entry_id: d.raw_entry_id.clone(),
            url: d.raw_url.clone(),
        })
        .collect();
    let mut flags = Vec::with_capacity(queries.len());
    for chunk in queries.chunks(CHUNK) {
        flags.extend(api.new_flags(ch.channel_id, chunk).await?);
    }
    let new_entries = flags.iter().filter(|f| **f).count();

    // 影モードでは OGP を取らない。取るはずだったものは pending にして比較から外す
    let resolved = drafts
        .into_iter()
        .map(|d| {
            let pending = d.image == shape::entry::ImageCandidate::NeedsOgp;
            (d, None, pending)
        })
        .collect();
    let (entries, more_skipped) = shape::entry::finalize_entries(resolved);
    skipped.extend(more_skipped);

    // finalize でバリデーション落ちや guid の重複が除かれて位置がずれるので、guid で引く
    let is_new: HashMap<String, bool> = guids_in_draft_order
        .into_iter()
        .zip(flags.iter().copied())
        .collect();
    let existing: Vec<String> = entries
        .iter()
        .filter(|e| is_new.get(&e.guid) == Some(&false))
        .map(|e| e.guid.clone())
        .collect();
    let mut stored = Vec::new();
    for chunk in existing.chunks(CHUNK) {
        stored.extend(api.stored_items(ch.channel_id, chunk).await?);
    }

    let mut diffs = compare_channel(&ch.stored, meta.as_ref(), format);
    diffs.extend(compare_entries(&entries, &stored));

    Ok(ChannelReport {
        channel_id: ch.channel_id,
        feed_url: ch.feed_url,
        status: "ok",
        error: None,
        format: Some(format),
        applied_filters: prepared.applied_filters,
        entries_in_feed,
        new_entries,
        entries_compared: stored.len(),
        skipped,
        diffs,
        elapsed_ms: started.elapsed().as_millis(),
    })
}

pub async fn run_shadow(opts: ShadowOptions) -> anyhow::Result<()> {
    let api = Arc::new(DispatcherClient::new(&opts.api_url, &opts.token)?);
    let http = Arc::new(HttpClient::new(opts.http.clone())?);
    let batch = api.shadow_channels(opts.max, &opts.order).await?;
    let _proxy_domains: HashSet<String> = batch.proxy_required_domains.into_iter().collect();

    let file = tokio::fs::File::create(&opts.out).await?;
    let writer = Arc::new(Mutex::new(file));
    let semaphore = Arc::new(Semaphore::new(opts.concurrency));
    let mut tasks = tokio::task::JoinSet::new();

    for ch in batch.channels {
        let (api, http, writer, semaphore) =
            (api.clone(), http.clone(), writer.clone(), semaphore.clone());
        tasks.spawn(async move {
            let _slot = semaphore.acquire_owned().await.unwrap();
            let channel_id = ch.channel_id;
            match process(ch, &http, &api).await {
                Ok(report) => {
                    let line = serde_json::to_string(&report).unwrap() + "\n";
                    writer
                        .lock()
                        .await
                        .write_all(line.as_bytes())
                        .await
                        .unwrap();
                }
                Err(e) => tracing::error!(channel_id, error = %e, "shadow failed"),
            }
        });
    }
    while tasks.join_next().await.is_some() {}
    writer.lock().await.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::EntryData;

    fn entry(guid: &str, title: &str, pending: bool) -> ShapedEntry {
        ShapedEntry {
            guid: guid.into(),
            title: title.into(),
            url: format!("https://e/{guid}"),
            image_url: None,
            published_at: "2026-09-24T00:00:00Z".into(),
            data: EntryData::default(),
            image_pending_ogp: pending,
        }
    }

    fn stored(guid: &str, title: &str, image: Option<&str>) -> StoredItem {
        StoredItem {
            guid: guid.into(),
            title: title.into(),
            url: format!("https://e/{guid}"),
            image_url: image.map(str::to_string),
            published_at: "2026-09-24T00:00:00Z".into(),
            data: EntryData::default(),
        }
    }

    #[test]
    fn reports_field_diffs_and_skips_ogp_images() {
        let rust = vec![entry("g1", "same", true), entry("g2", "rust title", false)];
        let rails = vec![
            stored("g1", "same", Some("https://e/ogp.png")),
            stored("g2", "rails title", None),
        ];
        let diffs = compare_entries(&rust, &rails);
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].field, "title");
        assert_eq!(diffs[0].guid.as_deref(), Some("g2"));
        assert_eq!(diffs[0].rails.as_deref(), Some("rails title"));
    }

    #[test]
    fn channel_description_is_ignored_for_youtube() {
        let stored = StoredChannel {
            title: "T".into(),
            description: Some("ogp".into()),
            site_url: Some("https://e/".into()),
            image_url: None,
        };
        let meta = ChannelMeta {
            title: Some("T".into()),
            description: None,
            site_url: Some("https://e/".into()),
            image_url: None,
        };
        assert!(compare_channel(&stored, Some(&meta), FeedFormat::AtomYoutube).is_empty());
        assert_eq!(
            compare_channel(&stored, Some(&meta), FeedFormat::Rss)[0].field,
            "description"
        );
        assert_eq!(
            compare_channel(&stored, None, FeedFormat::Rss)[0].field,
            "channel"
        );
    }
}
