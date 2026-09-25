use std::collections::HashMap;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
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
    /// entry の差分のとき、Rails がその item を保存した時刻。古い item ほど、差分が parser の違いではなく
    /// 保存後にフィード側で書き換わったもの (drift) である可能性が高い
    pub item_created_at: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct NewGuid {
    pub guid: String,
    pub published_at: String,
}

/// 保存済みの items との突き合わせの結果
#[derive(Debug)]
pub struct EntryComparison {
    /// dispatcher が「保存済み」と判定したエントリの数
    pub existing_flagged: usize,
    /// そのうち、保存済みの item を guid で引けて項目ごとに比べられた数
    pub entries_compared: usize,
    /// dispatcher が「未保存」と判定したエントリ
    pub new_guids: Vec<NewGuid>,
    pub diffs: Vec<FieldDiff>,
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
    pub existing_flagged: usize,
    pub entries_compared: usize,
    pub new_guids: Vec<NewGuid>,
    pub skipped: Vec<Skipped>,
    pub diffs: Vec<FieldDiff>,
    pub elapsed_ms: u128,
}

pub struct ShadowOptions {
    pub api_url: String,
    pub token: String,
    pub max: u32,
    pub order: String,
    /// dispatcher に渡す `scope` (`due` か `all`)。検証時は `all` で停止中を除く全チャンネルからサンプルする
    pub scope: String,
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
        item_created_at: None,
    })
}

/// Rails の Channel.build_from がチャンネル情報を作る形式か (それ以外の形式では Rails も nil を返すので、
/// Rust 側で作れなくても差分ではない)
fn rails_builds_channel(format: FeedFormat) -> bool {
    matches!(
        format,
        FeedFormat::Rss
            | FeedFormat::Atom
            | FeedFormat::AtomGoogleAlerts
            | FeedFormat::ItunesRss
            | FeedFormat::AtomYoutube
    )
}

pub fn compare_channel(
    stored: &StoredChannel,
    rust: Option<&ChannelMeta>,
    format: FeedFormat,
) -> Vec<FieldDiff> {
    let Some(meta) = rust else {
        if !rails_builds_channel(format) {
            return vec![];
        }
        return vec![FieldDiff {
            field: "channel",
            guid: None,
            rust: None,
            rails: Some(stored.title.clone()),
            item_created_at: None,
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

/// `is_new` は guid ごとの dispatcher の新規判定。保存済みと判定されたのに保存済みの item を guid で
/// 引けないもの (entry_id と url のどちらで一致したかで guid がずれる) は `guid` の差分として出す。
pub fn compare_entries(
    rust: &[ShapedEntry],
    is_new: &HashMap<String, bool>,
    stored: &[StoredItem],
) -> EntryComparison {
    let stored_by_guid: HashMap<&str, &StoredItem> =
        stored.iter().map(|s| (s.guid.as_str(), s)).collect();
    let mut out = EntryComparison {
        existing_flagged: 0,
        entries_compared: 0,
        new_guids: Vec::new(),
        diffs: Vec::new(),
    };
    for r in rust {
        match is_new.get(&r.guid) {
            Some(true) => {
                out.new_guids.push(NewGuid {
                    guid: r.guid.clone(),
                    published_at: r.published_at.clone(),
                });
                continue;
            }
            Some(false) => out.existing_flagged += 1,
            None => continue,
        }
        let Some(s) = stored_by_guid.get(r.guid.as_str()) else {
            out.diffs.push(FieldDiff {
                field: "guid",
                guid: Some(r.guid.clone()),
                rust: Some(r.guid.clone()),
                rails: None,
                item_created_at: None,
            });
            continue;
        };
        out.entries_compared += 1;
        let g = Some(s.guid.as_str());
        let mut diffs = Vec::new();
        diffs.extend(diff("title", g, Some(&r.title), Some(&s.title)));
        diffs.extend(diff("url", g, Some(&r.url), Some(&s.url)));
        diffs.extend(diff(
            "published_at",
            g,
            Some(&r.published_at),
            Some(&s.published_at),
        ));
        diffs.extend(diff(
            "summary",
            g,
            r.data.summary.as_deref(),
            s.data.summary.as_deref(),
        ));
        diffs.extend(diff(
            "itunes_subtitle",
            g,
            r.data.itunes_subtitle.as_deref(),
            s.data.itunes_subtitle.as_deref(),
        ));
        diffs.extend(diff(
            "enclosure_url",
            g,
            r.data.enclosure_url.as_deref(),
            s.data.enclosure_url.as_deref(),
        ));
        diffs.extend(diff(
            "enclosure_type",
            g,
            r.data.enclosure_type.as_deref(),
            s.data.enclosure_type.as_deref(),
        ));
        if !r.image_pending_ogp {
            diffs.extend(diff(
                "image_url",
                g,
                r.image_url.as_deref(),
                s.image_url.as_deref(),
            ));
        }
        for d in &mut diffs {
            d.item_created_at = s.created_at.clone();
        }
        out.diffs.extend(diffs);
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
        existing_flagged: 0,
        entries_compared: 0,
        new_guids: vec![],
        skipped: vec![],
        diffs: vec![],
        elapsed_ms: started.elapsed().as_millis(),
    }
}

async fn process(ch: ShadowChannel, http: &HttpClient, api: &DispatcherClient) -> ChannelReport {
    let started = Instant::now();
    let res = match http.get_feed(&ch.feed_url, ch.use_proxy).await {
        Ok(r) => r,
        Err(e) => {
            return empty_report(&ch, "fetch_error", format!("{}: {e}", e.kind()), started);
        }
    };
    let prepared = match crate::prepare(&res.body, &ch.feed_url) {
        Ok(p) => p,
        Err(e) => return empty_report(&ch, "parse_error", e.to_string(), started),
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
        match api.new_flags(ch.channel_id, chunk).await {
            Ok(f) => flags.extend(f),
            Err(e) => return dispatcher_error(&ch, "new-guids", e, started),
        }
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
        match api.stored_items(ch.channel_id, chunk).await {
            Ok(items) => stored.extend(items),
            Err(e) => return dispatcher_error(&ch, "stored items", e, started),
        }
    }

    let mut diffs = compare_channel(&ch.stored, meta.as_ref(), format);
    let cmp = compare_entries(&entries, &is_new, &stored);
    diffs.extend(cmp.diffs);

    ChannelReport {
        channel_id: ch.channel_id,
        feed_url: ch.feed_url,
        status: "ok",
        error: None,
        format: Some(format),
        applied_filters: prepared.applied_filters,
        entries_in_feed,
        new_entries,
        existing_flagged: cmp.existing_flagged,
        entries_compared: cmp.entries_compared,
        new_guids: cmp.new_guids,
        skipped,
        diffs,
        elapsed_ms: started.elapsed().as_millis(),
    }
}

fn dispatcher_error(
    ch: &ShadowChannel,
    call: &str,
    e: anyhow::Error,
    started: Instant,
) -> ChannelReport {
    tracing::error!(channel_id = ch.channel_id, call, error = %e, "dispatcher call failed");
    empty_report(ch, "dispatcher_error", format!("{call}: {e:#}"), started)
}

/// 出力先の親ディレクトリが無ければ作る (既定の `tmp/` が無い環境でも動くように)
async fn create_parent_dir(path: &Path) -> std::io::Result<()> {
    match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => tokio::fs::create_dir_all(parent).await,
        _ => Ok(()),
    }
}

pub async fn run_shadow(opts: ShadowOptions) -> anyhow::Result<()> {
    let api = Arc::new(DispatcherClient::new(&opts.api_url, &opts.token)?);
    let http = Arc::new(HttpClient::new(opts.http.clone())?);
    let batch = api
        .shadow_channels(opts.max, &opts.order, &opts.scope)
        .await?;

    create_parent_dir(&opts.out).await?;
    let file = tokio::fs::File::create(&opts.out).await?;
    let writer = Arc::new(Mutex::new(file));
    let semaphore = Arc::new(Semaphore::new(opts.concurrency));
    // レポート行の書き込みに一度でも失敗したチャンネルが無いか (シリアライズ失敗・書き込み失敗・タスクの
    // パニックやキャンセルを含む)。1チャンネル分のレポートが確実に失われたことを意味するので、実行全体を
    // 非ゼロ終了させる。dispatcher の呼び出し失敗など、チャンネル単体の処理失敗は status の違う行として書く。
    let write_failed = Arc::new(AtomicBool::new(false));
    let mut tasks = tokio::task::JoinSet::new();

    for ch in batch.channels {
        let (api, http, writer, semaphore, write_failed) = (
            api.clone(),
            http.clone(),
            writer.clone(),
            semaphore.clone(),
            write_failed.clone(),
        );
        tasks.spawn(async move {
            let _slot = semaphore
                .acquire_owned()
                .await
                .expect("semaphore is never closed");
            let channel_id = ch.channel_id;
            let report = process(ch, &http, &api).await;
            let line = match serde_json::to_string(&report) {
                Ok(s) => s + "\n",
                Err(e) => {
                    tracing::error!(channel_id, error = %e, "failed to serialize shadow report");
                    write_failed.store(true, Ordering::Relaxed);
                    return;
                }
            };
            if let Err(e) = writer.lock().await.write_all(line.as_bytes()).await {
                tracing::error!(channel_id, error = %e, "failed to write shadow report line");
                write_failed.store(true, Ordering::Relaxed);
            }
        });
    }
    while let Some(res) = tasks.join_next().await {
        if let Err(e) = res {
            tracing::error!(error = %e, "shadow task panicked or was cancelled, its report line was lost");
            write_failed.store(true, Ordering::Relaxed);
        }
    }
    writer.lock().await.flush().await?;
    if write_failed.load(Ordering::Relaxed) {
        anyhow::bail!("shadow: failed to write one or more channel report lines");
    }
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
            created_at: Some(format!("2026-09-2{}T00:00:00Z", guid.len())),
            data: EntryData::default(),
        }
    }

    fn flags(pairs: &[(&str, bool)]) -> HashMap<String, bool> {
        pairs.iter().map(|(g, f)| (g.to_string(), *f)).collect()
    }

    #[test]
    fn reports_field_diffs_and_skips_ogp_images() {
        let rust = vec![entry("g1", "same", true), entry("g2", "rust title", false)];
        let rails = vec![
            stored("g1", "same", Some("https://e/ogp.png")),
            stored("g2", "rails title", None),
        ];
        let cmp = compare_entries(&rust, &flags(&[("g1", false), ("g2", false)]), &rails);
        assert_eq!(cmp.diffs.len(), 1);
        assert_eq!(cmp.diffs[0].field, "title");
        assert_eq!(cmp.diffs[0].guid.as_deref(), Some("g2"));
        assert_eq!(cmp.diffs[0].rails.as_deref(), Some("rails title"));
        assert_eq!(
            cmp.diffs[0].item_created_at.as_deref(),
            Some("2026-09-22T00:00:00Z")
        );
        assert_eq!(cmp.existing_flagged, 2);
        assert_eq!(cmp.entries_compared, 2);
    }

    #[test]
    fn existing_flagged_entries_without_a_stored_row_are_guid_diffs() {
        // g2 は entry_id ではなく url で保存済みと判定されたが、保存済みの guid が違うので取れなかった
        let rust = vec![
            entry("g1", "t", false),
            entry("g2", "t", false),
            entry("g3", "t", false),
        ];
        let rails = vec![stored("g1", "t", None)];
        let cmp = compare_entries(
            &rust,
            &flags(&[("g1", false), ("g2", false), ("g3", true)]),
            &rails,
        );
        assert_eq!(cmp.existing_flagged, 2);
        assert_eq!(cmp.entries_compared, 1);
        assert_eq!(cmp.diffs.len(), 1);
        let d = &cmp.diffs[0];
        assert_eq!(d.field, "guid");
        assert_eq!(d.guid.as_deref(), Some("g2"));
        assert_eq!(d.rust.as_deref(), Some("g2"));
        assert_eq!(d.rails, None);
        assert_eq!(d.item_created_at, None);
        assert_eq!(cmp.new_guids.len(), 1);
        assert_eq!(cmp.new_guids[0].guid, "g3");
        assert_eq!(cmp.new_guids[0].published_at, "2026-09-24T00:00:00Z");
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

    #[test]
    fn missing_channel_meta_is_not_a_diff_for_formats_rails_does_not_build() {
        let stored = StoredChannel {
            title: "T".into(),
            description: None,
            site_url: None,
            image_url: None,
        };
        for format in [
            FeedFormat::RssFeedburner,
            FeedFormat::AtomFeedburner,
            FeedFormat::GoogleDocsAtom,
            FeedFormat::JsonFeed,
        ] {
            assert!(
                compare_channel(&stored, None, format).is_empty(),
                "{format:?}"
            );
        }
        for format in [
            FeedFormat::Rss,
            FeedFormat::Atom,
            FeedFormat::AtomGoogleAlerts,
            FeedFormat::ItunesRss,
            FeedFormat::AtomYoutube,
        ] {
            assert_eq!(
                compare_channel(&stored, None, format)[0].field,
                "channel",
                "{format:?}"
            );
        }
    }
}
