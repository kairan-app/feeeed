//! Channel.build_from_* とチャンネルのバリデーション・コールバックの再現。

use crate::filters::relative_url_resolver::resolve_like_rails;
use crate::model::{ChannelMeta, FeedFormat};
use crate::parse::extract::RawFeed;
use crate::ruby::{is_blank, ruby_strip, valid_url_column};

#[derive(Debug, Clone, Default)]
pub struct Ogp {
    pub title: Option<String>,
    pub description: Option<String>,
    pub image: Option<String>,
}

/// Channel.normalize_url
pub fn normalize_site_url(url: Option<&str>, feed_url: &str) -> String {
    match url {
        None => feed_url.to_string(),
        Some(u) if is_blank(u) => feed_url.to_string(),
        Some(u) => resolve_like_rails(u, feed_url),
    }
}

/// チャンネル情報のために OGP を取りに行く URL (iTunes と未対応形式は取りに行かない)
pub fn ogp_target(feed: &RawFeed, feed_url: &str) -> Option<String> {
    match feed.format {
        FeedFormat::Rss
        | FeedFormat::Atom
        | FeedFormat::AtomGoogleAlerts
        | FeedFormat::AtomYoutube => Some(normalize_site_url(feed.url.as_deref(), feed_url)),
        _ => None,
    }
}

fn blank_to_none(v: Option<String>) -> Option<String> {
    v.filter(|s| !is_blank(s))
}

/// Channel.build_from の結果を Channel のコールバックとバリデーションに通したもの。
/// バリデーションに通らなければ None (Rails では保存されない)。
pub fn channel_meta(feed: &RawFeed, feed_url: &str, ogp: Option<&Ogp>) -> Option<ChannelMeta> {
    let site_url = normalize_site_url(feed.url.as_deref(), feed_url);
    let ogp_image = || ogp.and_then(|o| o.image.clone());
    let (description, site_url, image_url) = match feed.format {
        FeedFormat::Rss => (feed.description.clone(), Some(site_url), ogp_image()),
        FeedFormat::Atom | FeedFormat::AtomGoogleAlerts => (
            feed.description.clone(),
            Some(feed.links.first().cloned().unwrap_or(site_url)),
            ogp_image(),
        ),
        FeedFormat::ItunesRss => (
            feed.description.clone(),
            Some(site_url),
            feed.itunes_image.clone(),
        ),
        FeedFormat::AtomYoutube => (
            ogp.and_then(|o| o.description.clone()),
            Some(site_url),
            ogp_image(),
        ),
        _ => return None,
    };

    // before_validation: 空文字を nil に
    let description = blank_to_none(description);
    let site_url = blank_to_none(site_url);
    let image_url = blank_to_none(image_url);
    let title = feed.title.clone();

    // validation (strip 前の値で行う)
    let title_ok = title
        .as_deref()
        .is_some_and(|t| !is_blank(t) && t.chars().count() <= 256);
    let description_ok = description
        .as_deref()
        .is_none_or(|d| d.chars().count() <= 1400);
    let urls_ok = [&site_url, &image_url]
        .iter()
        .all(|u| u.as_deref().is_none_or(valid_url_column));
    if !(title_ok && description_ok && urls_ok) {
        return None;
    }

    // before_save: strip
    Some(ChannelMeta {
        title: title.map(|t| ruby_strip(&t).to_string()),
        description: description.map(|d| ruby_strip(&d).to_string()),
        site_url,
        image_url,
    })
}
