//! Feedjira の `DateTime.parse(string).to_time.utc` の近似。
//! 読めない形式は None (Feedjira も nil にする)。

use chrono::{DateTime, FixedOffset, NaiveDate, NaiveDateTime, TimeZone, Utc};
use regex::Regex;
use std::sync::LazyLock;

const ZONES: [(&str, &str); 12] = [
    ("JST", "+0900"),
    ("KST", "+0900"),
    ("GMT", "+0000"),
    ("UTC", "+0000"),
    ("UT", "+0000"),
    ("EST", "-0500"),
    ("EDT", "-0400"),
    ("CST", "-0600"),
    ("CDT", "-0500"),
    ("MST", "-0700"),
    ("PST", "-0800"),
    ("PDT", "-0700"),
];

const WITH_ZONE: [&str; 6] = [
    "%a, %d %b %Y %H:%M:%S %z",
    "%d %b %Y %H:%M:%S %z",
    "%a, %d %b %Y %H:%M %z",
    "%Y-%m-%d %H:%M:%S %z",
    "%Y-%m-%d %H:%M:%S%z",
    "%Y-%m-%dT%H:%M:%S%.f%z",
];

const WITHOUT_ZONE: [&str; 6] = [
    "%Y-%m-%dT%H:%M:%S%.f",
    "%Y-%m-%d %H:%M:%S",
    "%a, %d %b %Y %H:%M:%S",
    "%d %b %Y %H:%M:%S",
    "%Y/%m/%d %H:%M:%S",
    "%Y/%m/%d %H:%M",
];

fn replace_zone_abbrev(s: &str) -> String {
    for (abbr, offset) in ZONES {
        if let Some(rest) = s.strip_suffix(abbr)
            && rest.ends_with(' ')
        {
            return format!("{rest}{offset}");
        }
    }
    s.to_string()
}

fn strip_weekday(s: &str) -> &str {
    match s.split_once(", ") {
        Some((day, rest)) if day.len() == 3 && day.chars().all(|c| c.is_ascii_alphabetic()) => rest,
        _ => s,
    }
}

/// 「金, 25 9月 2026 16:07:00 GMT」のように曜日と月を日本語にした RFC 822 形式
/// (Bing の検索フィードが日本からのアクセスに返す) を英語の表記に直す。
static JA_RFC822: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?:[日月火水木金土], )?(\d{1,2}) (\d{1,2})月 (\d{4} .*)$").unwrap()
});

const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

fn englishize_japanese(s: &str) -> Option<String> {
    let c = JA_RFC822.captures(s)?;
    let month: usize = c[2].parse().ok()?;
    let name = MONTHS.get(month.checked_sub(1)?)?;
    Some(format!("{} {name} {}", &c[1], &c[3]))
}

fn to_utc(d: DateTime<FixedOffset>) -> DateTime<Utc> {
    d.with_timezone(&Utc)
}

pub fn parse_datetime(s: &str) -> Option<DateTime<Utc>> {
    let t = s.trim();
    if t.is_empty() {
        return None;
    }
    if let Ok(d) = DateTime::parse_from_rfc3339(t) {
        return Some(to_utc(d));
    }
    let englishized = englishize_japanese(t);
    let normalized = replace_zone_abbrev(englishized.as_deref().unwrap_or(t));
    let candidates = [normalized.as_str(), strip_weekday(&normalized)];
    for c in candidates {
        if let Ok(d) = DateTime::parse_from_rfc2822(c) {
            return Some(to_utc(d));
        }
        for fmt in WITH_ZONE {
            if let Ok(d) = DateTime::parse_from_str(c, fmt) {
                return Some(to_utc(d));
            }
        }
        for fmt in WITHOUT_ZONE {
            if let Ok(n) = NaiveDateTime::parse_from_str(c, fmt) {
                return Some(Utc.from_utc_datetime(&n));
            }
        }
    }
    for fmt in ["%Y-%m-%d", "%Y/%m/%d"] {
        if let Ok(d) = NaiveDate::parse_from_str(t, fmt) {
            return Some(Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap()));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn iso(s: &str) -> String {
        parse_datetime(s)
            .unwrap()
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string()
    }

    #[test]
    fn parses_common_formats_like_ruby_datetime_parse() {
        assert_eq!(
            iso("Wed, 24 Sep 2026 10:00:00 +0900"),
            "2026-09-24T01:00:00Z"
        );
        assert_eq!(iso("Wed, 24 Sep 2026 10:00:00 GMT"), "2026-09-24T10:00:00Z");
        assert_eq!(iso("Wed, 24 Sep 2026 10:00:00 JST"), "2026-09-24T01:00:00Z");
        assert_eq!(
            iso("Mon, 24 Sep 2026 10:00:00 +0900"),
            "2026-09-24T01:00:00Z"
        ); // 曜日の不一致は無視
        assert_eq!(iso("24 Sep 2026 10:00:00 +0000"), "2026-09-24T10:00:00Z");
        assert_eq!(iso("2026-09-24T10:00:00+09:00"), "2026-09-24T01:00:00Z");
        assert_eq!(iso("2026-09-24T10:00:00.123Z"), "2026-09-24T10:00:00Z");
        assert_eq!(iso("2026-09-24 10:00:00"), "2026-09-24T10:00:00Z"); // タイムゾーン無しは UTC
        assert_eq!(iso("2026-09-24"), "2026-09-24T00:00:00Z");
        // rss_edge.golden.json の jst item
        assert_eq!(iso("Tue, 23 Sep 2026 10:00:00 JST"), "2026-09-23T01:00:00Z");
    }

    #[test]
    fn parses_japanese_localized_rfc822() {
        // Bing の検索フィードは日本からのアクセスに曜日と月を日本語にして返す。
        // Ruby の DateTime.parse は 10月以降を読み違え (1 10月 → 9月10日)、
        // 1月は曜日の「月」に引きずられて読めないので、Rails には合わせず正しく読む
        assert_eq!(iso("金, 25 9月 2026 16:07:00 GMT"), "2026-09-25T16:07:00Z");
        assert_eq!(iso("木, 1 10月 2026 01:02:03 GMT"), "2026-10-01T01:02:03Z");
        assert_eq!(
            iso("土, 26 12月 2026 04:10:00 +0900"),
            "2026-12-25T19:10:00Z"
        );
        assert_eq!(iso("月, 5 1月 2026 04:10:00 GMT"), "2026-01-05T04:10:00Z");
    }

    #[test]
    fn returns_none_for_garbage() {
        assert!(parse_datetime("not a date").is_none());
        assert!(parse_datetime("").is_none());
    }
}
