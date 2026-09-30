//! 名前付きのエンティティを直す (Ruby の HtmlEntityFixer)。

use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Value, json};

use super::PreParseFilter;
use super::html_entities::lookup;
use super::segments::map_unprotected;

static NAMED_REF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"&([A-Za-z][A-Za-z0-9]*);").unwrap());
const PREDEFINED: [&str; 5] = ["amp", "lt", "gt", "quot", "apos"];

pub struct HtmlEntityFixer;

impl PreParseFilter for HtmlEntityFixer {
    fn name(&self) -> &'static str {
        "HtmlEntityFixer"
    }

    fn apply(&self, xml: &str) -> Option<(String, Value)> {
        // 独自のエンティティを宣言している文書は、宣言済みの名前を壊さないよう対象外にする
        if xml.contains("<!ENTITY") || !NAMED_REF.is_match(xml) {
            return None;
        }
        let mut replaced = 0;
        let mut unknown = 0;
        let fixed = map_unprotected(xml, |text| {
            NAMED_REF
                .replace_all(text, |c: &regex::Captures| {
                    let name = &c[1];
                    if PREDEFINED.contains(&name) {
                        c[0].to_string()
                    } else if let Some(chars) = lookup(name) {
                        replaced += 1;
                        chars
                            .chars()
                            .map(|ch| format!("&#x{:X};", ch as u32))
                            .collect()
                    } else {
                        unknown += 1;
                        format!("&amp;{name};")
                    }
                })
                .into_owned()
        });
        (replaced + unknown > 0)
            .then(|| (fixed, json!({ "replaced": replaced, "unknown": unknown })))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(xml: &str) -> (String, Option<serde_json::Value>) {
        match HtmlEntityFixer.apply(xml) {
            Some((out, d)) => (out, Some(d)),
            None => (xml.to_string(), None),
        }
    }

    #[test]
    fn replaces_html_entities_in_text_and_attributes() {
        let (out, d) = run(r#"<a href="/?x=&nbsp;">&copy; 2026&hellip;</a>"#);
        assert_eq!(out, r#"<a href="/?x=&#xA0;">&#xA9; 2026&#x2026;</a>"#);
        assert_eq!(d.unwrap(), serde_json::json!({"replaced": 3, "unknown": 0}));
    }

    #[test]
    fn two_codepoint_entities() {
        assert_eq!(run("<a>&NotEqualTilde;</a>").0, "<a>&#x2242;&#x338;</a>");
    }

    #[test]
    fn unknown_names_become_literal() {
        let (out, d) = run("<a>&foo; &bar;</a>");
        assert_eq!(out, "<a>&amp;foo; &amp;bar;</a>");
        assert_eq!(d.unwrap(), serde_json::json!({"replaced": 0, "unknown": 2}));
    }

    #[test]
    fn predefined_and_numeric_refs_are_kept() {
        let xml = "<a>&amp;&lt;&gt;&quot;&apos;&#65;&#x41;</a>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }

    #[test]
    fn cdata_and_comments_are_kept() {
        let xml = "<a><![CDATA[&nbsp;]]><!-- &copy; --></a>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }

    #[test]
    fn documents_declaring_entities_are_skipped() {
        let xml = r#"<!DOCTYPE rss [<!ENTITY myent "x">]><a>&myent;&nbsp;</a>"#;
        assert_eq!(run(xml), (xml.to_string(), None));
    }
}
