//! RelativeUrlResolver と Channel.normalize_url の再現。
//! RelativeUrlResolver はフィードの URL を基準に RFC 3986 のとおり解決する。
//! Channel.normalize_url 用の resolve_like_rails は scheme://host[:port] 基準のまま。

use std::sync::LazyLock;

use regex::Regex;
use serde_json::json;

use crate::parse::extract::RawFeed;
use crate::ruby::ruby_strip;

fn has_relative_url(url: Option<&str>) -> bool {
    match url.map(ruby_strip) {
        None => false,
        Some("") => false,
        Some(u) => !(u.starts_with("http://") || u.starts_with("https://")),
    }
}

/// RFC 3986 の付録 B の正規表現で URI を分解する (Addressable::URI.parse と同じ分け方)
static URI_PARTS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?s)^(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$").unwrap()
});
static SCHEME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z][A-Za-z0-9+.\-]*$").unwrap());

struct UriParts<'a> {
    scheme: Option<&'a str>,
    authority: Option<&'a str>,
    path: &'a str,
    query: Option<&'a str>,
    fragment: Option<&'a str>,
}

fn split_uri(s: &str) -> UriParts<'_> {
    let c = URI_PARTS
        .captures(s)
        .expect("この正規表現はどんな文字列にも一致する");
    let get = |i| c.get(i).map(|m| m.as_str());
    UriParts {
        scheme: get(1),
        authority: get(2),
        path: get(3).unwrap_or(""),
        query: get(4),
        fragment: get(5),
    }
}

impl UriParts<'_> {
    fn query_and_fragment(&self) -> String {
        let mut out = String::new();
        if let Some(q) = self.query {
            out.push('?');
            out.push_str(q);
        }
        if let Some(f) = self.fragment {
            out.push('#');
            out.push_str(f);
        }
        out
    }
}

/// RFC 3986 5.2.4 remove_dot_segments
fn remove_dot_segments(path: &str) -> String {
    fn pop_last(output: &mut String) {
        match output.rfind('/') {
            Some(i) => output.truncate(i),
            None => output.clear(),
        }
    }
    let mut input = path.to_string();
    let mut output = String::new();
    while !input.is_empty() {
        if input.starts_with("../") {
            input.drain(..3);
        } else if input.starts_with("./") {
            input.drain(..2);
        } else if input.starts_with("/./") {
            input.replace_range(..3, "/");
        } else if input == "/." {
            input = "/".to_string();
        } else if input.starts_with("/../") {
            input.replace_range(..4, "/");
            pop_last(&mut output);
        } else if input == "/.." {
            input = "/".to_string();
            pop_last(&mut output);
        } else if input == "." || input == ".." {
            input.clear();
        } else {
            let from = usize::from(input.starts_with('/'));
            let end = input[from..].find('/').map_or(input.len(), |i| i + from);
            output.push_str(&input[..end]);
            input.drain(..end);
        }
    }
    output
}

/// `scheme://host[:port]` (既定のポートは省く)。Addressable と同じく host は書かれたまま
/// (小文字化も punycode 化もしない) 使い、userinfo は落とす。
pub fn base_url(feed_url: &str) -> Option<String> {
    let parts = split_uri(feed_url);
    let scheme = parts.scheme?;
    let authority = parts.authority?;
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, hp)| hp);
    let (host, port) = if host_port.starts_with('[') {
        match host_port.find(']') {
            Some(i) => (&host_port[..=i], host_port[i + 1..].strip_prefix(':')),
            None => (host_port, None),
        }
    } else {
        match host_port.rsplit_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (host_port, None),
        }
    };
    let default_port = match scheme.to_ascii_lowercase().as_str() {
        "http" => Some(80),
        "https" => Some(443),
        _ => None,
    };
    let port = port
        .and_then(|p| p.parse::<u16>().ok())
        .filter(|p| Some(*p) != default_port)
        .map(|p| format!(":{p}"))
        .unwrap_or_default();
    Some(format!("{scheme}://{host}{port}"))
}

/// Addressable::URI.join(base, url) を RFC 3986 5.2.2 のとおりに再現する。
/// Addressable と同じく文字のエンコードや大文字小文字の正規化はしない。
pub fn join_like_addressable(base: &str, url: &str) -> String {
    let r = split_uri(url);
    let rest = r.query_and_fragment();
    if let Some(scheme) = r.scheme {
        // Addressable は不正なスキームで InvalidURIError を投げ、Rails ではフィードの取り込み全体が
        // 失敗する。ここでは再現せず、そのまま返す
        if !SCHEME.is_match(scheme) {
            return url.to_string();
        }
        let authority = r.authority.map(|a| format!("//{a}")).unwrap_or_default();
        return format!("{scheme}:{authority}{}{rest}", remove_dot_segments(r.path));
    }
    let b = split_uri(base);
    let scheme = b.scheme.unwrap_or_default();
    if let Some(authority) = r.authority {
        return format!(
            "{scheme}://{authority}{}{rest}",
            remove_dot_segments(r.path)
        );
    }
    let prefix = match b.authority {
        Some(a) => format!("{scheme}://{a}"),
        None => format!("{scheme}:"),
    };
    if r.path.is_empty() {
        let mut out = format!("{prefix}{}", b.path);
        if let Some(q) = r.query.or(b.query) {
            out.push('?');
            out.push_str(q);
        }
        if let Some(f) = r.fragment {
            out.push('#');
            out.push_str(f);
        }
        return out;
    }
    let path = if r.path.starts_with('/') {
        remove_dot_segments(r.path)
    } else if b.authority.is_some() && b.path.is_empty() {
        remove_dot_segments(&format!("/{}", r.path))
    } else {
        let dir = b.path.rfind('/').map_or("", |i| &b.path[..=i]);
        remove_dot_segments(&format!("{dir}{}", r.path))
    };
    format!("{prefix}{path}{rest}")
}

pub fn resolve_like_rails(url: &str, feed_url: &str) -> String {
    if url.starts_with("http://") || url.starts_with("https://") {
        return url.to_string();
    }
    let Some(base) = base_url(feed_url) else {
        return url.to_string();
    };
    if url.starts_with('/') {
        return format!("{base}{url}");
    }
    join_like_addressable(&base, url)
}

pub fn apply(feed: &mut RawFeed, feed_url: &str) -> Option<serde_json::Value> {
    let applicable = has_relative_url(feed.url.as_deref())
        || feed
            .entries
            .iter()
            .any(|e| has_relative_url(e.url.as_deref()));
    if !applicable {
        return None;
    }

    let mut converted = Vec::new();
    if let Some(from) = feed.url.clone().filter(|u| has_relative_url(Some(u))) {
        let to = join_like_addressable(feed_url, ruby_strip(&from));
        converted.push(json!({ "from": from, "to": to, "target": "feed" }));
        feed.url = Some(to);
    }
    for entry in &mut feed.entries {
        if let Some(from) = entry.url.clone().filter(|u| has_relative_url(Some(u))) {
            let to = join_like_addressable(feed_url, ruby_strip(&from));
            converted.push(json!({ "from": from, "to": to, "target": "entry" }));
            entry.url = Some(to);
        }
    }

    let count = converted.len();
    Some(json!({
        "base_url": feed_url,
        "converted_count": count,
        "sample_urls": converted.into_iter().take(5).collect::<Vec<_>>(),
        "has_more": count > 5,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::FeedFormat;
    use crate::parse::extract::{RawEntry, RawFeed};

    fn feed(url: Option<&str>, entry_urls: &[&str]) -> RawFeed {
        RawFeed {
            format: FeedFormat::Rss,
            title: None,
            description: None,
            url: url.map(str::to_string),
            links: vec![],
            itunes_image: None,
            entries: entry_urls
                .iter()
                .map(|u| RawEntry {
                    url: Some(u.to_string()),
                    ..RawEntry::default()
                })
                .collect(),
        }
    }

    #[test]
    fn resolves_against_feed_url_like_rfc3986() {
        let base = "https://example.com/blog/feed.xml";
        assert_eq!(
            join_like_addressable(base, "/post/1"),
            "https://example.com/post/1"
        );
        assert_eq!(
            join_like_addressable(base, "post/2"),
            "https://example.com/blog/post/2"
        );
        assert_eq!(
            join_like_addressable(base, "../post/3"),
            "https://example.com/post/3"
        );
        assert_eq!(
            join_like_addressable(base, "?page=2"),
            "https://example.com/blog/feed.xml?page=2"
        );
        assert_eq!(
            join_like_addressable(base, "#top"),
            "https://example.com/blog/feed.xml#top"
        );
        assert_eq!(
            join_like_addressable(base, "//cdn.example.com/x"),
            "https://cdn.example.com/x"
        );
    }

    #[test]
    fn surrounding_whitespace_is_ignored() {
        let mut f = feed(
            Some("https://example.com/"),
            &["\n  https://example.com/a\n", "\n/b\n"],
        );
        let details = apply(&mut f, "https://example.com/blog/feed.xml").unwrap();
        assert_eq!(
            f.entries[0].url.as_deref(),
            Some("\n  https://example.com/a\n")
        );
        assert_eq!(f.entries[1].url.as_deref(), Some("https://example.com/b"));
        assert_eq!(details["base_url"], "https://example.com/blog/feed.xml");
    }

    #[test]
    fn uppercase_scheme_and_tag_links_are_left_as_is() {
        let mut f = feed(
            Some("https://example.com/"),
            &["HTTPS://example.com/upper", "tag:example.com,2026:1"],
        );
        apply(&mut f, "https://example.com/blog/feed.xml");
        assert_eq!(
            f.entries[0].url.as_deref(),
            Some("HTTPS://example.com/upper")
        );
        assert_eq!(f.entries[1].url.as_deref(), Some("tag:example.com,2026:1"));
    }

    #[test]
    fn resolves_against_feed_url() {
        let mut f = feed(
            Some("/"),
            &["/post/1", "post/2", "http://example.com/post/3"],
        );
        let details = apply(&mut f, "http://example.com/blog/feed.xml").unwrap();
        assert_eq!(f.url.as_deref(), Some("http://example.com/"));
        assert_eq!(
            f.entries[0].url.as_deref(),
            Some("http://example.com/post/1")
        );
        assert_eq!(
            f.entries[1].url.as_deref(),
            Some("http://example.com/blog/post/2")
        );
        assert_eq!(
            f.entries[2].url.as_deref(),
            Some("http://example.com/post/3")
        );
        assert_eq!(details["converted_count"], 3);
        assert_eq!(details["base_url"], "http://example.com/blog/feed.xml");
    }

    #[test]
    fn keeps_non_default_port() {
        let mut f = feed(None, &["/a"]);
        apply(&mut f, "https://example.com:8080/feed.xml").unwrap();
        assert_eq!(
            f.entries[0].url.as_deref(),
            Some("https://example.com:8080/a")
        );
    }

    #[test]
    fn not_applied_when_all_absolute() {
        let mut f = feed(Some("https://example.com/"), &["https://example.com/1"]);
        assert!(apply(&mut f, "https://example.com/feed.xml").is_none());
    }
    // 期待値は Rails の Channel.normalize_url (Addressable::URI.join) の実際の出力
    #[test]
    fn resolves_like_addressable() {
        let f = "https://Example.com:443/blog/feed.xml";
        let cases = [
            ("post/2", "https://Example.com/post/2"),
            ("日本/a b", "https://Example.com/日本/a b"),
            ("./x/../y", "https://Example.com/y"),
            ("?q=1", "https://Example.com?q=1"),
            ("#f", "https://Example.com#f"),
            ("mailto:a@b", "mailto:a@b"),
            ("javascript:alert(1)", "javascript:alert(1)"),
            ("HTTP://EX.com/a", "HTTP://EX.com/a"),
            ("//cdn.example/x", "https://Example.com//cdn.example/x"),
            (" post", "https://Example.com/ post"),
        ];
        for (url, expected) in cases {
            assert_eq!(resolve_like_rails(url, f), expected, "url: {url}");
        }
        let g = "http://e.com/f";
        let cases = [
            ("mailto:../x", "mailto:x"),
            ("a:b", "a:b"),
            ("..", "http://e.com/"),
            ("a/./b/.", "http://e.com/a/b/"),
            ("x?q#f", "http://e.com/x?q#f"),
            ("HTTP://ex.com/a/../b", "HTTP://ex.com/b"),
        ];
        for (url, expected) in cases {
            assert_eq!(resolve_like_rails(url, g), expected, "url: {url}");
        }
    }

    #[test]
    fn base_url_keeps_host_as_written() {
        let rel = "a/../../b?x=1#y";
        let cases = [
            (
                "https://Example.com:443/blog/feed.xml",
                "https://Example.com/b?x=1#y",
            ),
            (
                "http://user:pw@例え.jp:8080/f",
                "http://例え.jp:8080/b?x=1#y",
            ),
            ("http://[::1]:80/f", "http://[::1]/b?x=1#y"),
            ("HTTPS://EXAMPLE.COM/f", "HTTPS://EXAMPLE.COM/b?x=1#y"),
        ];
        for (feed_url, expected) in cases {
            assert_eq!(
                resolve_like_rails(rel, feed_url),
                expected,
                "feed_url: {feed_url}"
            );
        }
    }
}
