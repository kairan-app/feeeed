//! Channel#fetch_and_save_items と Item のバリデーション・コールバックの再現。

use std::collections::HashMap;

use chrono::{DateTime, Utc};

use crate::model::{EntryData, ShapedEntry, SkipReason, Skipped};
use crate::parse::extract::RawFeed;
use crate::ruby::{is_blank, matches_uri_http, opt_presence, ruby_strip, valid_url_column};

#[derive(Debug, Clone, PartialEq)]
pub enum ImageCandidate {
    Direct(String),
    NeedsOgp,
}

/// items.data の残り4キー (entry_id, title, url, published)
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize)]
pub struct DataExtra {
    pub entry_id: Option<String>,
    pub title: Option<String>,
    pub url: Option<String>,
    pub published: Option<String>,
}

#[derive(Debug, Clone)]
pub struct EntryDraft {
    /// new-guids の判定に使う (Rails の exists?(guid: entry_id))
    pub raw_entry_id: Option<String>,
    /// 同上 (exists?(guid: url))
    pub raw_url: Option<String>,
    pub guid: String,
    pub title_raw: Option<String>,
    /// エンコード済み
    pub url: String,
    pub published: Option<DateTime<Utc>>,
    pub image: ImageCandidate,
    pub data: EntryData,
    pub data_extra: DataExtra,
}

/// マルチバイト文字と `"` だけをパーセントエンコードする (Rails と同じ)
pub fn encode_url_like_rails(url: &str) -> String {
    let mut out = String::with_capacity(url.len());
    for c in url.chars() {
        if c.len_utf8() > 1 {
            let mut buf = [0u8; 4];
            for b in c.encode_utf8(&mut buf).bytes() {
                out.push_str(&format!("%{b:02X}"));
            }
        } else if c == '"' {
            out.push_str("%22");
        } else {
            out.push(c);
        }
    }
    out
}

/// entry を published の昇順に並べ、URL・guid・画像の候補を決める (OGP はまだ取らない)。
pub fn draft_entries(feed: &RawFeed, site_url: Option<&str>) -> (Vec<EntryDraft>, Vec<Skipped>) {
    let mut entries: Vec<_> = feed.entries.iter().collect();
    // Ruby の sort_by は安定ソートではない。published も guid も同じ entry が複数あるときだけ
    // 後勝ちになる entry が Rails と食い違いうる (こちらは安定ソートで元の順番を保つ)
    entries.sort_by_key(|e| e.published.unwrap_or(DateTime::<Utc>::UNIX_EPOCH));

    let mut drafts = Vec::new();
    let mut skipped = Vec::new();
    for entry in entries {
        let url = opt_presence(entry.url.as_deref())
            .or_else(|| {
                if entry.is_itunes_item {
                    opt_presence(entry.enclosure_url.as_deref())
                } else {
                    None
                }
            })
            .or_else(|| opt_presence(site_url));
        let Some(url) = url else {
            skipped.push(Skipped {
                title: entry.title.clone(),
                reason: SkipReason::NoUrl,
            });
            continue;
        };
        let encoded = encode_url_like_rails(ruby_strip(url));

        let Some(guid) = entry.entry_id.clone().or_else(|| entry.url.clone()) else {
            skipped.push(Skipped {
                title: entry.title.clone(),
                reason: SkipReason::NoGuid,
            });
            continue;
        };

        let image = if let Some(img) = entry.itunes_image.clone().filter(|_| entry.is_itunes_item) {
            ImageCandidate::Direct(img)
        } else if let Some(img) = entry.image.clone() {
            ImageCandidate::Direct(img)
        } else if let Some(id) = guid.strip_prefix("yt:video:") {
            ImageCandidate::Direct(format!("https://img.youtube.com/vi/{id}/maxresdefault.jpg"))
        } else {
            ImageCandidate::NeedsOgp
        };

        drafts.push(EntryDraft {
            raw_entry_id: entry.entry_id.clone(),
            raw_url: entry.url.clone(),
            guid,
            title_raw: entry.title.clone(),
            url: encoded,
            published: entry.published,
            image,
            data: EntryData {
                summary: entry.summary.clone(),
                itunes_subtitle: entry.itunes_subtitle.clone(),
                enclosure_url: entry.enclosure_url.clone(),
                enclosure_type: entry.enclosure_type.clone(),
            },
            data_extra: DataExtra {
                entry_id: entry.entry_id.clone(),
                title: entry.title.clone(),
                url: entry.url.clone(),
                // ActiveSupport の Time#as_json と同じ (ミリ秒まで、UTC は Z)
                published: entry
                    .published
                    .map(|p| p.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()),
            },
        });
    }
    (drafts, skipped)
}

/// 画像を確定させ、Item のコールバックとバリデーションを当てる。
/// 同じ guid が複数あれば、後に処理したもので上書きする (find_or_initialize_by + update!)。
/// タプルは (draft, OGP で取れた画像, OGP を取らずに済ませたか)。
pub fn finalize_entries(
    drafts: Vec<(EntryDraft, Option<String>, bool)>,
) -> (Vec<ShapedEntry>, Vec<Skipped>) {
    let mut by_guid: HashMap<String, ShapedEntry> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut skipped = Vec::new();

    for (draft, ogp_image, pending) in drafts {
        let image = match draft.image {
            ImageCandidate::Direct(i) => Some(i),
            ImageCandidate::NeedsOgp => ogp_image,
        };
        // 不正な image_url は nil に落とす
        let image = image.filter(|i| is_blank(i) || matches_uri_http(i));
        // before_validation: 空文字を nil に、タイトルが空なら 〓
        let image = image.filter(|i| !is_blank(i));
        let title = match &draft.title_raw {
            Some(t) if !is_blank(t) => t.clone(),
            _ => "〓".to_string(),
        };

        let Some(published) = draft.published else {
            skipped.push(Skipped {
                title: draft.title_raw,
                reason: SkipReason::ValidationFailed,
            });
            continue;
        };
        let valid = title.chars().count() <= 256
            && !is_blank(&draft.guid)
            && draft.guid.chars().count() <= 2083
            && !is_blank(&draft.url)
            && valid_url_column(&draft.url)
            && image.as_deref().is_none_or(valid_url_column);
        if !valid {
            skipped.push(Skipped {
                title: draft.title_raw,
                reason: SkipReason::ValidationFailed,
            });
            continue;
        }

        // before_save: strip
        let shaped = ShapedEntry {
            guid: draft.guid.clone(),
            title: ruby_strip(&title).to_string(),
            url: draft.url,
            image_url: image.map(|i| ruby_strip(&i).to_string()),
            published_at: published.format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            data: draft.data,
            image_pending_ogp: pending,
        };
        if !by_guid.contains_key(&draft.guid) {
            order.push(draft.guid.clone());
        }
        by_guid.insert(draft.guid, shaped);
    }

    let entries = order
        .into_iter()
        .filter_map(|g| by_guid.remove(&g))
        .collect();
    (entries, skipped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_extra_published_matches_active_support_json() {
        let feed = RawFeed {
            format: crate::model::FeedFormat::Rss,
            title: None,
            description: None,
            url: None,
            links: vec![],
            itunes_image: None,
            entries: vec![crate::parse::extract::RawEntry {
                url: Some("https://example.com/1".into()),
                published: Some("2026-09-22T00:00:00Z".parse().unwrap()),
                ..Default::default()
            }],
        };
        let (drafts, _) = draft_entries(&feed, None);
        assert_eq!(
            drafts[0].data_extra.published.as_deref(),
            Some("2026-09-22T00:00:00.000Z")
        );
    }

    #[test]
    fn encodes_multibyte_chars_and_double_quotes_only() {
        assert_eq!(
            encode_url_like_rails("https://e/日本?q=\"x\" y"),
            "https://e/%E6%97%A5%E6%9C%AC?q=%22x%22 y"
        );
    }
}
