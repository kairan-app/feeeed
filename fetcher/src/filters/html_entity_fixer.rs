//! copyright / generator の中の HTML エンティティを実際の文字に直す。
//! Ruby 版は Nokogiri で文書全体を読み直すが、ここでは対象タグの中身だけを書き換える。

use std::sync::LazyLock;

use regex::Regex;
use serde_json::json;

use super::PreParseFilter;

const TARGET_TAGS: [&str; 2] = ["copyright", "generator"];

static APPLICABLE: LazyLock<Vec<(&'static str, Regex)>> = LazyLock::new(|| {
    TARGET_TAGS
        .iter()
        .map(|tag| {
            (
                *tag,
                Regex::new(&format!(r"<{tag}[^>]*>([^<]*)&[a-zA-Z]+;")).unwrap(),
            )
        })
        .collect()
});

static ELEMENT: LazyLock<Vec<(&'static str, Regex)>> = LazyLock::new(|| {
    TARGET_TAGS
        .iter()
        .map(|tag| {
            (
                *tag,
                Regex::new(&format!(r"(<{tag}(?:\s[^>]*)?>)([^<]*)(</{tag}>)")).unwrap(),
            )
        })
        .collect()
});

// Ruby 版は `doc.xpath("//channel/#{tag}")` で channel の直下だけを対象にする。
// ここでは「<channel>...</channel> の中で、かつ <item>...</item> の中ではない」箇所を
// その近似として扱う (DOTALL、非貪欲マッチ。ネストした channel/item は想定しない)。
static CHANNEL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?s)<channel(?:\s[^>]*)?>.*?</channel>").unwrap());
static ITEM: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?s)<item(?:\s[^>]*)?>.*?</item>").unwrap());

pub struct HtmlEntityFixer;

fn xml_escape_text(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// channel の中身 (channel 開始タグ〜終了タグまで) のうち、item の外側にある
/// 対象タグだけをデコードして書き換える。
fn rewrite_channel(channel: &str) -> (String, Vec<&'static str>) {
    let item_ranges: Vec<(usize, usize)> = ITEM
        .find_iter(channel)
        .map(|m| (m.start(), m.end()))
        .collect();
    let in_item = |pos: usize| item_ranges.iter().any(|&(s, e)| pos >= s && pos < e);

    let mut edits: Vec<(usize, usize, String, &'static str)> = Vec::new();
    for (tag, re) in ELEMENT.iter() {
        for caps in re.captures_iter(channel) {
            let whole = caps.get(0).unwrap();
            if in_item(whole.start()) {
                continue;
            }
            let decoded = html_escape::decode_html_entities(&caps[2]).to_string();
            let replacement = format!("{}{}{}", &caps[1], xml_escape_text(&decoded), &caps[3]);
            if replacement != whole.as_str() {
                edits.push((whole.start(), whole.end(), replacement, tag));
            }
        }
    }
    edits.sort_by_key(|e| e.0);

    let mut result = String::with_capacity(channel.len());
    let mut fixed_tags: Vec<&'static str> = Vec::new();
    let mut last_end = 0usize;
    for (start, end, replacement, tag) in edits {
        result.push_str(&channel[last_end..start]);
        result.push_str(&replacement);
        last_end = end;
        if !fixed_tags.contains(&tag) {
            fixed_tags.push(tag);
        }
    }
    result.push_str(&channel[last_end..]);
    (result, fixed_tags)
}

impl PreParseFilter for HtmlEntityFixer {
    fn name(&self) -> &'static str {
        "HtmlEntityFixer"
    }

    fn apply(&self, xml: &str) -> Option<(String, serde_json::Value)> {
        let applicable = APPLICABLE
            .iter()
            .any(|(tag, re)| xml.contains(&format!("<{tag}")) && re.is_match(xml));
        if !applicable {
            return None;
        }

        let mut result = String::with_capacity(xml.len());
        let mut fixed_tags: Vec<&'static str> = Vec::new();
        let mut last_end = 0usize;
        for m in CHANNEL.find_iter(xml) {
            result.push_str(&xml[last_end..m.start()]);
            let (rewritten, tags) = rewrite_channel(m.as_str());
            result.push_str(&rewritten);
            last_end = m.end();
            for tag in tags {
                if !fixed_tags.contains(&tag) {
                    fixed_tags.push(tag);
                }
            }
        }
        result.push_str(&xml[last_end..]);

        if fixed_tags.is_empty() {
            return None;
        }
        Some((
            result,
            json!({ "fixed_tags": fixed_tags, "reason": "HTML entities in tags converted to actual characters" }),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::filters::PreParseFilter;

    #[test]
    fn decodes_entities_in_copyright_and_generator() {
        let xml = "<rss><channel><copyright>&copy; 2026</copyright><generator>G &trade;</generator><title>t &amp; u</title></channel></rss>";
        let (fixed, details) = HtmlEntityFixer.apply(xml).unwrap();
        assert!(fixed.contains("<copyright>© 2026</copyright>"));
        assert!(fixed.contains("<generator>G ™</generator>"));
        assert!(fixed.contains("<title>t &amp; u</title>"));
        assert_eq!(
            details["fixed_tags"],
            serde_json::json!(["copyright", "generator"])
        );
    }

    #[test]
    fn not_applicable_without_entities() {
        assert!(
            HtmlEntityFixer
                .apply("<rss><channel><copyright>2026</copyright></channel></rss>")
                .is_none()
        );
    }

    #[test]
    fn re_escapes_xml_special_chars() {
        let xml = "<rss><channel><copyright>&copy; A &lt; B</copyright></channel></rss>";
        let (fixed, _) = HtmlEntityFixer.apply(xml).unwrap();
        assert!(fixed.contains("<copyright>© A &lt; B</copyright>"));
    }

    #[test]
    fn not_applicable_outside_channel() {
        let xml =
            r#"<feed xmlns="http://www.w3.org/2005/Atom"><generator>G &trade;</generator></feed>"#;
        assert!(HtmlEntityFixer.apply(xml).is_none());
    }

    #[test]
    fn only_rewrites_channel_level_element_not_item_level() {
        let xml = "<rss><channel><copyright>&copy; y</copyright><item><copyright>&copy; x</copyright></item></channel></rss>";
        let (fixed, details) = HtmlEntityFixer.apply(xml).unwrap();
        assert!(fixed.contains("<copyright>© y</copyright>"));
        assert!(fixed.contains("<copyright>&copy; x</copyright>"));
        assert_eq!(details["fixed_tags"], serde_json::json!(["copyright"]));
    }
}
