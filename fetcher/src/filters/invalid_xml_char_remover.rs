//! XML 1.0 で使えない文字を取り除く (Ruby の InvalidXmlCharRemover)。

use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Value, json};

use super::PreParseFilter;
use super::segments::map_unprotected;

static CHAR_REF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"&#(?:x([0-9A-Fa-f]+)|([0-9]+));").unwrap());

fn is_xml_char_code(code: u64) -> bool {
    matches!(code, 0x9 | 0xA | 0xD | 0x20..=0xD7FF | 0xE000..=0xFFFD | 0x10000..=0x10FFFF)
}

fn is_invalid_char(c: char) -> bool {
    matches!(c, '\u{0}'..='\u{8}' | '\u{b}' | '\u{c}' | '\u{e}'..='\u{1f}' | '\u{fffe}' | '\u{ffff}')
}

pub struct InvalidXmlCharRemover;

impl PreParseFilter for InvalidXmlCharRemover {
    fn name(&self) -> &'static str {
        "InvalidXmlCharRemover"
    }

    fn apply(&self, xml: &str) -> Option<(String, Value)> {
        let mut removed_chars = 0;
        let without_chars: String = xml
            .chars()
            .filter(|&c| {
                let invalid = is_invalid_char(c);
                if invalid {
                    removed_chars += 1;
                }
                !invalid
            })
            .collect();
        let mut removed_refs = 0;
        let fixed = map_unprotected(&without_chars, |text| {
            CHAR_REF
                .replace_all(text, |c: &regex::Captures| {
                    // 桁が多すぎて u64 に収まらないものも、使えない文字として扱う
                    let code = match (c.get(1), c.get(2)) {
                        (Some(h), _) => u64::from_str_radix(h.as_str(), 16).ok(),
                        (_, Some(d)) => d.as_str().parse::<u64>().ok(),
                        _ => None,
                    };
                    if code.is_some_and(is_xml_char_code) {
                        c[0].to_string()
                    } else {
                        removed_refs += 1;
                        String::new()
                    }
                })
                .into_owned()
        });
        (removed_chars + removed_refs > 0).then(|| {
            (
                fixed,
                json!({ "removed_chars": removed_chars, "removed_refs": removed_refs }),
            )
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(xml: &str) -> (String, Option<serde_json::Value>) {
        match InvalidXmlCharRemover.apply(xml) {
            Some((out, d)) => (out, Some(d)),
            None => (xml.to_string(), None),
        }
    }

    #[test]
    fn removes_raw_chars_everywhere() {
        let (out, d) = run("<a>x\u{8}y<![CDATA[p\u{1}q]]>\u{fffe}</a>");
        assert_eq!(out, "<a>xy<![CDATA[pq]]></a>");
        assert_eq!(
            d.unwrap(),
            serde_json::json!({"removed_chars": 3, "removed_refs": 0})
        );
    }

    #[test]
    fn removes_invalid_char_refs_outside_cdata() {
        let (out, d) = run(r#"<a b="&#x1F;">&#8;&#xD800;&#1114112;<![CDATA[&#8;]]></a>"#);
        assert_eq!(out, r#"<a b=""><![CDATA[&#8;]]></a>"#);
        assert_eq!(
            d.unwrap(),
            serde_json::json!({"removed_chars": 0, "removed_refs": 4})
        );
    }

    #[test]
    fn removes_char_refs_too_large_for_u64() {
        // 桁が多すぎて u64 に収まらない数値文字参照も、使えない文字として取り除く
        let (out, d) = run("<a>&#99999999999999999999;</a>");
        assert_eq!(out, "<a></a>");
        assert_eq!(
            d.unwrap(),
            serde_json::json!({"removed_chars": 0, "removed_refs": 1})
        );
    }

    #[test]
    fn keeps_allowed_chars_and_refs() {
        let (out, d) = run("<a>\t\n\r&#9;&#xA;&#x3042;&#65;</a>");
        assert_eq!(out, "<a>\t\n\r&#9;&#xA;&#x3042;&#65;</a>");
        assert!(d.is_none());
    }
}
