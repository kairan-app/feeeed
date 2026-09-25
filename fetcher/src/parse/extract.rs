//! Feedjira の SAXMachine クラスから `RawFeed` / `RawEntry` を組み立てる。
//!
//! フィード側の `url` の決め方はフォーマットごとに実際の Ruby の宣言に合わせている
//! (`classes.rs` の冒頭コメント参照):
//! - `Atom`: `@url || (links - [feed_url]).last`
//! - `AtomGoogleAlerts`: `@url` そのもの (フォールバック無し)
//! - `AtomFeedburner`: `@url_text_html || @url_notype` (`links` は無い)
//! - それ以外 (`Rss` / `ItunesRss` / `RssFeedburner`): `@url` そのもの

use chrono::{DateTime, Utc};
use scraper::Html;

use super::classes;
use super::date::parse_datetime;
use super::detect::detect_format;
use super::sax::{Class, Obj, parse};
use crate::model::FeedFormat;

#[derive(Debug, Clone, Default)]
pub struct RawEntry {
    pub title: Option<String>,
    pub url: Option<String>,
    pub entry_id: Option<String>,
    pub published: Option<DateTime<Utc>>,
    pub summary: Option<String>,
    pub itunes_subtitle: Option<String>,
    pub itunes_image: Option<String>,
    pub image: Option<String>,
    pub enclosure_url: Option<String>,
    pub enclosure_type: Option<String>,
    /// ITunesRSSItem のとき true (Rails の `respond_to?(:enclosure_url)` / `respond_to?(:itunes_image)`)
    pub is_itunes_item: bool,
}

#[derive(Debug, Clone)]
pub struct RawFeed {
    pub format: FeedFormat,
    pub title: Option<String>,
    pub description: Option<String>,
    /// Feedjira の feed.url (Atom は `@url || (links - [feed_url]).last`)
    pub url: Option<String>,
    /// Atom の links (build_from_atom の site_url に使う)
    pub links: Vec<String>,
    pub itunes_image: Option<String>,
    pub entries: Vec<RawEntry>,
}

#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("no parser available")]
    NoParser,
    #[error("unsupported format: {0:?}")]
    Unsupported(FeedFormat),
}

fn class_for(format: FeedFormat) -> Option<&'static Class> {
    Some(match format {
        FeedFormat::ItunesRss => &classes::ITUNES,
        FeedFormat::RssFeedburner => &classes::RSS_FEEDBURNER,
        FeedFormat::AtomYoutube => &classes::YOUTUBE,
        FeedFormat::AtomFeedburner => &classes::ATOM_FEEDBURNER,
        FeedFormat::AtomGoogleAlerts => &classes::GOOGLE_ALERTS,
        FeedFormat::Atom => &classes::ATOM,
        FeedFormat::Rss => &classes::RSS,
        FeedFormat::GoogleDocsAtom | FeedFormat::JsonFeed => return None,
    })
}

fn owned(v: Option<&str>) -> Option<String> {
    v.map(str::to_string)
}

/// Loofah.fragment(s).xpath("normalize-space(.)") の近似
fn html_normalize_space(s: &str) -> String {
    let text: String = Html::parse_fragment(s).root_element().text().collect();
    text.split([' ', '\t', '\n', '\r'])
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

fn published(obj: &Obj) -> Option<DateTime<Utc>> {
    obj.get("published")
        .or(obj.get("updated"))
        .and_then(parse_datetime)
}

fn rss_entry(obj: &Obj, is_itunes_item: bool) -> RawEntry {
    let guid = obj.child("entry_id");
    let entry_id = guid.and_then(|g| g.get("guid"));
    let perma_link = guid
        .map(|g| g.get("is_perma_link") != Some("false"))
        .unwrap_or(false);
    let url = owned(obj.get("url")).or_else(|| if perma_link { owned(entry_id) } else { None });
    RawEntry {
        title: owned(obj.get("title")),
        url,
        entry_id: owned(entry_id),
        published: published(obj),
        summary: owned(obj.get("summary")),
        itunes_subtitle: owned(obj.get("itunes_subtitle")),
        itunes_image: owned(obj.get("itunes_image")),
        image: owned(obj.get("image")),
        enclosure_url: owned(obj.get("enclosure_url")),
        enclosure_type: owned(obj.get("enclosure_type")),
        is_itunes_item,
    }
}

fn atom_entry(obj: &Obj) -> RawEntry {
    let title = owned(obj.get("title")).or_else(|| obj.get("raw_title").map(html_normalize_space));
    let url = owned(obj.get("url")).or_else(|| obj.all("links").first().cloned());
    RawEntry {
        title,
        url,
        entry_id: owned(obj.get("entry_id")),
        published: published(obj),
        summary: owned(obj.get("summary")),
        image: owned(obj.get("image")),
        ..RawEntry::default()
    }
}

fn unwrap_google_url(url: Option<String>) -> Option<String> {
    let url = url?;
    if !url.starts_with("https://www.google.com/url?") {
        return None;
    }
    let parsed = url::Url::parse(&url).ok()?;
    parsed
        .query_pairs()
        .find(|(k, _)| k == "url")
        .map(|(_, v)| v.into_owned())
}

/// フィード側の `url` (フォーマットごとに Ruby の宣言に合わせる。`classes.rs` 冒頭のコメント参照)
fn feed_url(root: &Obj, links: &[String], format: FeedFormat) -> Option<String> {
    match format {
        FeedFormat::Atom => {
            let self_link = root.get("feed_url");
            owned(root.get("url")).or_else(|| {
                links
                    .iter()
                    .rfind(|l| Some(l.as_str()) != self_link)
                    .cloned()
            })
        }
        FeedFormat::AtomFeedburner => {
            owned(root.get("url_text_html")).or_else(|| owned(root.get("url_notype")))
        }
        _ => owned(root.get("url")),
    }
}

pub fn parse_feed(xml: &str) -> Result<RawFeed, ParseError> {
    let format = detect_format(xml).ok_or(ParseError::NoParser)?;
    let class = class_for(format).ok_or(ParseError::Unsupported(format))?;
    let root = parse(xml, class);

    let entries = root
        .list("entries")
        .iter()
        .map(|e| match format {
            FeedFormat::Rss => rss_entry(e, false),
            FeedFormat::ItunesRss => rss_entry(e, true),
            FeedFormat::RssFeedburner => {
                let mut entry = rss_entry(e, false);
                entry.url = owned(e.get("orig_link")).or(entry.url);
                entry
            }
            FeedFormat::AtomFeedburner => {
                let mut entry = atom_entry(e);
                entry.url = owned(e.get("orig_link")).or(entry.url);
                entry
            }
            FeedFormat::AtomGoogleAlerts => {
                let mut entry = atom_entry(e);
                entry.url = unwrap_google_url(entry.url);
                entry
            }
            _ => atom_entry(e),
        })
        .collect();

    let links = root.all("links").to_vec();
    let url = feed_url(&root, &links, format);

    Ok(RawFeed {
        format,
        title: owned(root.get("title")),
        description: owned(root.get("description")),
        url,
        links,
        itunes_image: owned(root.get("itunes_image")),
        entries,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rss_entry_url_falls_back_to_permalink_guid() {
        let xml = r#"<rss><channel><title>T</title><link>https://e/</link>
            <item><guid>https://e/1</guid></item>
            <item><guid isPermaLink="false">x</guid></item>
        </channel></rss>"#;
        let feed = parse_feed(xml).unwrap();
        assert_eq!(feed.entries[0].url.as_deref(), Some("https://e/1"));
        assert_eq!(feed.entries[0].entry_id.as_deref(), Some("https://e/1"));
        assert_eq!(feed.entries[1].url, None);
        assert_eq!(feed.entries[1].entry_id.as_deref(), Some("x"));
    }

    #[test]
    fn atom_feed_url_and_entry_title() {
        let xml = r#"<feed xmlns="http://www.w3.org/2005/Atom"><title>A</title>
            <link href="https://e/feed" rel="self"/><link href="https://e/a"/><link href="https://e/b"/>
            <entry><title type="html">&lt;b&gt;x&lt;/b&gt;
              y</title><link href="https://e/1"/><id>i1</id><updated>2026-09-24T00:00:00Z</updated></entry>
        </feed>"#;
        let feed = parse_feed(xml).unwrap();
        assert_eq!(feed.url.as_deref(), Some("https://e/b"));
        assert_eq!(
            feed.links,
            vec!["https://e/feed", "https://e/a", "https://e/b"]
        );
        let e = &feed.entries[0];
        assert_eq!(e.title.as_deref(), Some("x y"));
        assert_eq!(e.url.as_deref(), Some("https://e/1"));
        assert!(e.published.is_some()); // published が無ければ updated
    }

    #[test]
    fn google_alerts_url_is_unwrapped_or_nil() {
        let xml = r#"<feed xmlns="http://www.w3.org/2005/Atom"><id>tag:google.com,2005:reader/user/1/state/com.google/alerts/2</id>
            <entry><link href="https://www.google.com/url?rct=j&amp;url=https://n.example/a&amp;ct=ga"/></entry>
            <entry><link href="https://n.example/b"/></entry></feed>"#;
        let feed = parse_feed(xml).unwrap();
        assert_eq!(feed.entries[0].url.as_deref(), Some("https://n.example/a"));
        assert_eq!(feed.entries[1].url, None);
    }

    #[test]
    fn itunes_item_enclosure_is_not_an_image() {
        let xml = r#"<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
            <itunes:image href="https://e/c.jpg"/>
            <item><enclosure url="https://e/1.mp3" type="audio/mpeg"/><itunes:subtitle>s</itunes:subtitle></item>
        </channel></rss>"#;
        let feed = parse_feed(xml).unwrap();
        assert_eq!(feed.itunes_image.as_deref(), Some("https://e/c.jpg"));
        let e = &feed.entries[0];
        assert!(e.is_itunes_item);
        assert_eq!(e.image, None);
        assert_eq!(e.enclosure_url.as_deref(), Some("https://e/1.mp3"));
        assert_eq!(e.enclosure_type.as_deref(), Some("audio/mpeg"));
        assert_eq!(e.itunes_subtitle.as_deref(), Some("s"));
    }

    #[test]
    fn unsupported_and_unknown() {
        assert!(matches!(
            parse_feed(r#"{"version":"https://jsonfeed.org/version/1"}"#),
            Err(ParseError::Unsupported(_))
        ));
        assert!(matches!(parse_feed("<html/>"), Err(ParseError::NoParser)));
    }
}
