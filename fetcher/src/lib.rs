pub mod encoding;
pub mod filters;
pub mod model;
pub mod parse;
pub mod ruby;
pub mod shape;

use model::ShapedFeed;
use parse::extract::{ParseError, RawFeed, parse_feed};
use serde_json::{Map, Value};

pub struct Prepared {
    pub feed: RawFeed,
    pub applied_filters: Vec<String>,
    pub filter_details: Map<String, Value>,
}

/// 文字コードの修正 → パース前フィルタ → パース → パース後フィルタ (FeedNormalizer と同じ流れ)
pub fn prepare(body: &[u8], feed_url: &str) -> Result<Prepared, ParseError> {
    let xml = encoding::to_utf8_dropping_invalid(body);
    let (xml, mut applied, mut details) = filters::apply_pre_parse(xml);
    let mut feed = parse_feed(&xml)?;
    if let Some(detail) = filters::relative_url_resolver::apply(&mut feed, feed_url) {
        applied.push("RelativeUrlResolver".to_string());
        details.insert("RelativeUrlResolver".to_string(), detail);
    }
    Ok(Prepared {
        feed,
        applied_filters: applied,
        filter_details: details,
    })
}

/// HTTP を使わずに、Rails の取り込みと同じ規則で整形する (OGP は取れなかった扱い)。
pub fn golden_output(body: &[u8], feed_url: &str) -> anyhow::Result<ShapedFeed> {
    let prepared = prepare(body, feed_url)?;
    let channel = shape::channel::channel_meta(&prepared.feed, feed_url, None);
    let site_url = channel.as_ref().and_then(|c| c.site_url.clone());
    let (drafts, mut skipped) = shape::entry::draft_entries(&prepared.feed, site_url.as_deref());
    let (entries, more_skipped) =
        shape::entry::finalize_entries(drafts.into_iter().map(|d| (d, None, false)).collect());
    skipped.extend(more_skipped);

    let mut out = ShapedFeed {
        format: prepared.feed.format,
        channel,
        applied_filters: prepared.applied_filters,
        entries,
        skipped,
    };
    out.normalize_order();
    Ok(out)
}
