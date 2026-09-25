//! Feedjira 4.0.2 の既定のパーサ順 (`Feedjira::Configuration#default_parsers`) と同じ判定をする。
//!
//! 対応する Ruby の `able_to_parse?` (`bundle show feedjira` の `lib/feedjira/parser/*.rb`):
//! - ITunesRSS: `xml.gsub(/<!\[CDATA\[.*?\]\]>/m, "")` してから `xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"` を探す
//! - RSSFeedBurner: `(/<rss|<rdf/ =~ xml) && xml.include?("feedburner")`
//! - GoogleDocsAtom: `<id>https?://docs.google.com/...</id>`
//! - AtomYoutube: `xml.include?('xmlns:yt="http://www.youtube.com/xml/schemas/2015"')`
//! - AtomFeedBurner: `xml.include?("<feed") && xml.include?("Atom") && xml.include?("feedburner") && !(/<rss|<rdf/ =~ xml)`
//! - AtomGoogleAlerts: `Atom.able_to_parse?(xml) && (%r{<id>tag:google\.com,2005:[^<]+/com\.google/alerts/} === xml)`
//! - Atom: `%r{<feed[^>]+xmlns\s?=\s?["'](https?://www\.w3\.org/2005/Atom|http://purl\.org/atom/ns#)["'][^>]*>}`
//! - RSS: `(/<rss|<rdf/ =~ xml) && !xml.include?("feedburner")`
//! - JSONFeed: `json.include?("https://jsonfeed.org/version/") || json.include?('https:\/\/jsonfeed.org\/version\/')`

use std::sync::LazyLock;

use regex::Regex;

use crate::model::FeedFormat;

static CDATA: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<!\[CDATA\[.*?\]\]>").unwrap());
static ITUNES: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)xmlns:itunes\s?=\s?["']http://www\.itunes\.com/dtds/podcast-1\.0\.dtd["']"#)
        .unwrap()
});
static RSS_OR_RDF: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<rss|<rdf").unwrap());
static GOOGLE_DOCS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<id>https?://docs\.google\.com/.*</id>").unwrap());
static ATOM: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"<feed[^>]+xmlns\s?=\s?["'](https?://www\.w3\.org/2005/Atom|http://purl\.org/atom/ns#)["'][^>]*>"#).unwrap()
});
static GOOGLE_ALERTS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<id>tag:google\.com,2005:[^<]+/com\.google/alerts/").unwrap());

/// Feedjira 4.0.2 の既定のパーサ順 (Feedjira::Configuration#default_parsers) と同じ判定をする。
pub fn detect_format(xml: &str) -> Option<FeedFormat> {
    let rss_or_rdf = RSS_OR_RDF.is_match(xml);
    let feedburner = xml.contains("feedburner");
    if ITUNES.is_match(&CDATA.replace_all(xml, "")) {
        return Some(FeedFormat::ItunesRss);
    }
    if rss_or_rdf && feedburner {
        return Some(FeedFormat::RssFeedburner);
    }
    if GOOGLE_DOCS.is_match(xml) {
        return Some(FeedFormat::GoogleDocsAtom);
    }
    if xml.contains(r#"xmlns:yt="http://www.youtube.com/xml/schemas/2015""#) {
        return Some(FeedFormat::AtomYoutube);
    }
    if xml.contains("<feed") && xml.contains("Atom") && feedburner && !rss_or_rdf {
        return Some(FeedFormat::AtomFeedburner);
    }
    let atom = ATOM.is_match(xml);
    if atom && GOOGLE_ALERTS.is_match(xml) {
        return Some(FeedFormat::AtomGoogleAlerts);
    }
    if atom {
        return Some(FeedFormat::Atom);
    }
    if rss_or_rdf && !feedburner {
        return Some(FeedFormat::Rss);
    }
    if xml.contains("https://jsonfeed.org/version/")
        || xml.contains(r"https:\/\/jsonfeed.org\/version\/")
    {
        return Some(FeedFormat::JsonFeed);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_in_feedjira_order() {
        let itunes =
            r#"<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel/></rss>"#;
        assert_eq!(detect_format(itunes), Some(FeedFormat::ItunesRss));
        // CDATA の中の itunes 名前空間は無視する
        let in_cdata = r#"<rss><channel><description><![CDATA[xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"]]></description></channel></rss>"#;
        assert_eq!(detect_format(in_cdata), Some(FeedFormat::Rss));
        assert_eq!(
            detect_format("<rss><channel>feedburner</channel></rss>"),
            Some(FeedFormat::RssFeedburner)
        );
        let yt = r#"<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">"#;
        assert_eq!(detect_format(yt), Some(FeedFormat::AtomYoutube));
        let alerts = r#"<feed xmlns="http://www.w3.org/2005/Atom"><id>tag:google.com,2005:reader/user/1/state/com.google/alerts/2</id>"#;
        assert_eq!(detect_format(alerts), Some(FeedFormat::AtomGoogleAlerts));
        assert_eq!(
            detect_format(r#"<feed xmlns="https://www.w3.org/2005/Atom">"#),
            Some(FeedFormat::Atom)
        );
        assert_eq!(
            detect_format(r#"{"version":"https://jsonfeed.org/version/1.1"}"#),
            Some(FeedFormat::JsonFeed)
        );
        assert_eq!(detect_format("<html></html>"), None);
    }
}
