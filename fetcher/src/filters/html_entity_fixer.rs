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

pub struct HtmlEntityFixer;

fn xml_escape_text(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
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

        let mut current = xml.to_string();
        let mut fixed_tags: Vec<&str> = Vec::new();
        for (tag, re) in ELEMENT.iter() {
            let replaced = re.replace_all(&current, |caps: &regex::Captures| {
                let decoded = html_escape::decode_html_entities(&caps[2]).to_string();
                format!("{}{}{}", &caps[1], xml_escape_text(&decoded), &caps[3])
            });
            if replaced != current {
                fixed_tags.push(tag);
                current = replaced.into_owned();
            }
        }

        if fixed_tags.is_empty() {
            return None;
        }
        Some((
            current,
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
}
