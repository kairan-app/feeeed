//! Rails の POST /fetcher/leases/:channel_id/result に送る取得結果。
//! 形は Rails の FetchResultApplier と、testdata/result/*.json のサンプルで固定する

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::model::{ChannelMeta, ShapedEntry};
use crate::parse::extract::{RawEntry, RawFeed};
use crate::ruby::ruby_strip;
use crate::shape;
use crate::shape::entry::{DataExtra, EntryDraft};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResultError {
    pub kind: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResultChannel {
    pub title: Option<String>,
    pub description: Option<String>,
    pub site_url: Option<String>,
    pub image_url: Option<String>,
    pub applied_filters: Vec<String>,
    pub filter_details: Map<String, Value>,
}

/// items.data に入れる8つのキー (Rails の画面が使うのは summary・itunes_subtitle・enclosure_*)
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ResultEntryData {
    pub entry_id: Option<String>,
    pub title: Option<String>,
    pub url: Option<String>,
    pub published: Option<String>,
    pub summary: Option<String>,
    pub itunes_subtitle: Option<String>,
    pub enclosure_url: Option<String>,
    pub enclosure_type: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResultEntry {
    pub guid: String,
    pub title: String,
    pub url: String,
    pub image_url: Option<String>,
    pub published_at: String,
    pub data: ResultEntryData,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResultPayload {
    pub fetched: bool,
    pub error: Option<ResultError>,
    /// リダイレクトしたときだけ、最後に取れた URL
    pub final_url: Option<String>,
    /// proxy を通して取れた URL (Rails がホストを proxy_required_domains に登録する)
    pub register_proxy_urls: Vec<String>,
    /// Rails の Channel.build_from が作らない形式や、バリデーションに通らないときは None (更新しない)
    pub channel: Option<ResultChannel>,
    /// 新しい entry だけ。公開日時の昇順
    pub entries: Vec<ResultEntry>,
    /// 新着通知の対象 (公開日時が新しい2件の entry_id と url)
    pub latest_guids: Vec<String>,
}

impl ResultPayload {
    pub fn failed(kind: &str, message: impl Into<String>) -> Self {
        Self {
            fetched: false,
            error: Some(ResultError {
                kind: kind.to_string(),
                message: message.into(),
            }),
            final_url: None,
            register_proxy_urls: vec![],
            channel: None,
            entries: vec![],
            latest_guids: vec![],
        }
    }
}

fn entry_id_of(e: &RawEntry) -> Option<String> {
    e.entry_id.clone().filter(|id| !ruby_strip(id).is_empty())
}

/// Rails の notifiable_guids と同じ: published のある entry を published の昇順に並べた最後の2件の、entry_id と url
pub fn latest_guids(feed: &RawFeed) -> Vec<String> {
    let mut dated: Vec<&RawEntry> = feed
        .entries
        .iter()
        .filter(|e| e.published.is_some())
        .collect();
    dated.sort_by_key(|e| e.published);
    let start = dated.len().saturating_sub(2);
    dated[start..]
        .iter()
        .flat_map(|e| [entry_id_of(e), e.url.clone()])
        .flatten()
        .collect()
}

/// finalize_entries は guid の重複を後勝ちで1つにするので、data の残りのキーも後勝ちで引けるようにする
pub fn data_extra_by_guid(drafts: &[EntryDraft]) -> HashMap<String, DataExtra> {
    drafts
        .iter()
        .map(|d| (d.guid.clone(), d.data_extra.clone()))
        .collect()
}

pub fn result_channel(
    meta: ChannelMeta,
    applied_filters: Vec<String>,
    filter_details: Map<String, Value>,
) -> ResultChannel {
    ResultChannel {
        title: meta.title,
        description: meta.description,
        site_url: meta.site_url,
        image_url: meta.image_url,
        applied_filters,
        filter_details,
    }
}

pub fn result_entry(entry: ShapedEntry, extra: Option<&DataExtra>) -> ResultEntry {
    let extra = extra.cloned().unwrap_or_default();
    ResultEntry {
        guid: entry.guid,
        title: entry.title,
        url: entry.url,
        image_url: entry.image_url,
        published_at: entry.published_at,
        data: ResultEntryData {
            entry_id: extra.entry_id,
            title: extra.title,
            url: extra.url,
            published: extra.published,
            summary: entry.data.summary,
            itunes_subtitle: entry.data.itunes_subtitle,
            enclosure_url: entry.data.enclosure_url,
            enclosure_type: entry.data.enclosure_type,
        },
    }
}

/// 契約のサンプル用: HTTP を使わず、全 entry を新しいものとして result を作る (OGP は取れなかった扱い)
pub fn sample_payload(body: &[u8], feed_url: &str) -> anyhow::Result<ResultPayload> {
    let prepared = crate::prepare(body, feed_url)?;
    let meta = shape::channel::channel_meta(&prepared.feed, feed_url, None);
    let site_url = meta.as_ref().and_then(|m| m.site_url.clone());
    let (drafts, _) = shape::entry::draft_entries(&prepared.feed, site_url.as_deref());
    let extras = data_extra_by_guid(&drafts);
    let (entries, _) =
        shape::entry::finalize_entries(drafts.into_iter().map(|d| (d, None, false)).collect());
    Ok(ResultPayload {
        fetched: true,
        error: None,
        final_url: None,
        register_proxy_urls: vec![],
        channel: meta.map(|m| {
            result_channel(
                m,
                prepared.applied_filters.clone(),
                prepared.filter_details.clone(),
            )
        }),
        entries: entries
            .into_iter()
            .map(|e| {
                let extra = extras.get(&e.guid);
                result_entry(e, extra)
            })
            .collect(),
        latest_guids: latest_guids(&prepared.feed),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::extract::{RawEntry, RawFeed};

    fn raw(entry_id: Option<&str>, url: Option<&str>, hour: Option<u32>) -> RawEntry {
        RawEntry {
            entry_id: entry_id.map(str::to_string),
            url: url.map(str::to_string),
            published: hour.map(|h| format!("2026-09-25T{h:02}:00:00Z").parse().unwrap()),
            ..Default::default()
        }
    }

    fn feed(entries: Vec<RawEntry>) -> RawFeed {
        RawFeed {
            format: crate::model::FeedFormat::Rss,
            title: None,
            description: None,
            url: None,
            links: vec![],
            itunes_image: None,
            entries,
        }
    }

    #[test]
    fn latest_guids_are_entry_ids_and_urls_of_the_two_newest() {
        let f = feed(vec![
            raw(Some("old"), Some("https://e/old"), Some(1)),
            raw(Some("newest"), Some("https://e/newest"), Some(9)),
            raw(None, Some("https://e/no-date"), None),
            raw(Some(" "), Some("https://e/second"), Some(5)),
        ]);
        assert_eq!(
            latest_guids(&f),
            vec!["https://e/second", "newest", "https://e/newest"]
        );
    }

    #[test]
    fn failed_payload_has_no_entries() {
        let p = ResultPayload::failed("timeout", "timed out");
        assert!(!p.fetched);
        assert_eq!(p.error.as_ref().unwrap().kind, "timeout");
        assert!(p.entries.is_empty());
        assert_eq!(
            serde_json::to_value(&p).unwrap()["error"],
            serde_json::json!({ "kind": "timeout", "message": "timed out" })
        );
    }
}
