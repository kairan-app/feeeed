//! 曜日と月が日本語の日時を英語の表記に直す (Ruby の LocalizedDateFixer)。

use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Value, json};

use super::PreParseFilter;
use super::segments::map_unprotected;

static DATE_ELEMENT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<(pubDate|lastBuildDate|dc:date)>([^<]*)<").unwrap());
static JA_DATE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?s)^([ \t\r\n]*)(?:[日月火水木金土],[ \t\r\n]*)?([0-9]{1,2})[ \t\r\n]+([0-9]{1,2})月[ \t\r\n]+([0-9]{4}(?:[ \t\r\n].*)?)$",
    )
    .unwrap()
});
const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

pub struct LocalizedDateFixer;

impl PreParseFilter for LocalizedDateFixer {
    fn name(&self) -> &'static str {
        "LocalizedDateFixer"
    }

    fn apply(&self, xml: &str) -> Option<(String, Value)> {
        if !xml.contains('月') {
            return None;
        }
        let mut fixed_count = 0;
        let fixed = map_unprotected(xml, |text| {
            DATE_ELEMENT
                .replace_all(text, |c: &regex::Captures| {
                    let Some(d) = JA_DATE.captures(&c[2]) else {
                        return c[0].to_string();
                    };
                    let month: usize = d[3].parse().unwrap_or(0);
                    let Some(name) = month.checked_sub(1).and_then(|i| MONTHS.get(i)) else {
                        return c[0].to_string();
                    };
                    fixed_count += 1;
                    format!("<{}>{}{} {name} {}<", &c[1], &d[1], &d[2], &d[4])
                })
                .into_owned()
        });
        (fixed_count > 0).then(|| (fixed, json!({ "fixed": fixed_count })))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(xml: &str) -> (String, Option<serde_json::Value>) {
        match LocalizedDateFixer.apply(xml) {
            Some((out, d)) => (out, Some(d)),
            None => (xml.to_string(), None),
        }
    }

    #[test]
    fn rewrites_japanese_dates() {
        let xml = "<item><pubDate>金, 25 9月 2026 16:07:00 GMT</pubDate>\
                   <dc:date>木, 1 10月 2026 01:02:03 GMT</dc:date>\
                   <lastBuildDate>26 12月 2026</lastBuildDate>\
                   <pubDate>月, 5 1月 2026 04:10:00 +0900</pubDate></item>";
        let (out, d) = run(xml);
        assert_eq!(
            out,
            "<item><pubDate>25 Sep 2026 16:07:00 GMT</pubDate>\
             <dc:date>1 Oct 2026 01:02:03 GMT</dc:date>\
             <lastBuildDate>26 Dec 2026</lastBuildDate>\
             <pubDate>5 Jan 2026 04:10:00 +0900</pubDate></item>"
        );
        assert_eq!(d.unwrap(), serde_json::json!({"fixed": 4}));
    }

    #[test]
    fn leaves_english_dates_and_other_elements() {
        let xml = "<item><title>9月の予定 25 9月 2026</title><pubDate>Fri, 25 Sep 2026 16:07:00 GMT</pubDate></item>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }

    #[test]
    fn leaves_invalid_month() {
        let xml = "<pubDate>1 13月 2026</pubDate>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }
}
