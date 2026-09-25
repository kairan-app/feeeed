pub mod dispatcher_client;
pub mod encoding;
pub mod filters;
pub mod http;
pub mod model;
pub mod ogp;
pub mod parse;
pub mod ruby;
pub mod shadow;
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

/// DIR/*.xml ごとに golden_output と DIR/<name>.golden.json を比べ、一致しないものを表示する。
pub fn golden_check(dir: &std::path::Path) -> anyhow::Result<()> {
    let mut failures = 0;
    let mut total = 0;
    let mut paths: Vec<_> = std::fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "xml"))
        .collect();
    paths.sort();
    for xml in paths {
        let name = xml.file_stem().unwrap().to_string_lossy().to_string();
        let golden_path = dir.join(format!("{name}.golden.json"));
        let Ok(golden) = std::fs::read_to_string(&golden_path) else {
            continue;
        };
        total += 1;
        let url_path = dir.join(format!("{name}.url"));
        let feed_url = std::fs::read_to_string(&url_path)
            .map(|s| s.lines().next().unwrap_or_default().trim().to_string())
            .unwrap_or_else(|_| format!("https://example.com/{name}/feed.xml"));
        let expected: model::ShapedFeed = serde_json::from_str(&golden)?;
        match golden_output(&std::fs::read(&xml)?, &feed_url) {
            Ok(actual) if actual == expected => {}
            Ok(actual) => {
                failures += 1;
                println!("MISMATCH {name}");
                println!("  expected: {}", serde_json::to_string(&expected)?);
                println!("  actual:   {}", serde_json::to_string(&actual)?);
            }
            Err(e) => {
                failures += 1;
                println!("ERROR {name}: {e}");
            }
        }
    }
    println!("{} / {} matched", total - failures, total);
    Ok(())
}
