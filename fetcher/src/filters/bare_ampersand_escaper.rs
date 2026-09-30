//! 文字参照の形になっていない & を &amp; にする (Ruby の BareAmpersandEscaper)。

use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Value, json};

use super::PreParseFilter;
use super::segments::map_unprotected;

static REF_AHEAD: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^&(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#x[0-9A-Fa-f]+);").unwrap());

pub struct BareAmpersandEscaper;

impl PreParseFilter for BareAmpersandEscaper {
    fn name(&self) -> &'static str {
        "BareAmpersandEscaper"
    }

    fn apply(&self, xml: &str) -> Option<(String, Value)> {
        if !xml.contains('&') {
            return None;
        }
        let mut escaped = 0;
        let fixed = map_unprotected(xml, |text| {
            let mut out = String::with_capacity(text.len());
            let mut rest = text;
            while let Some(i) = rest.find('&') {
                out.push_str(&rest[..i]);
                if REF_AHEAD.is_match(&rest[i..]) {
                    out.push('&');
                } else {
                    escaped += 1;
                    out.push_str("&amp;");
                }
                rest = &rest[i + 1..];
            }
            out.push_str(rest);
            out
        });
        (escaped > 0).then(|| (fixed, json!({ "escaped": escaped })))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(xml: &str) -> (String, Option<serde_json::Value>) {
        match BareAmpersandEscaper.apply(xml) {
            Some((out, d)) => (out, Some(d)),
            None => (xml.to_string(), None),
        }
    }

    #[test]
    fn escapes_bare_ampersands() {
        let (out, d) = run(r#"<a href="/?a=1&b=2">Q & A &</a>"#);
        assert_eq!(out, r#"<a href="/?a=1&amp;b=2">Q &amp; A &amp;</a>"#);
        assert_eq!(d.unwrap(), serde_json::json!({"escaped": 3}));
    }

    #[test]
    fn keeps_refs() {
        let xml = "<a>&amp;&foo;&#65;&#x41;</a>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }

    #[test]
    fn uppercase_x_is_not_a_char_ref() {
        assert_eq!(run("<a>&#X41;</a>").0, "<a>&amp;#X41;</a>");
    }

    #[test]
    fn cdata_is_kept() {
        let xml = "<a><![CDATA[a & b]]></a>";
        assert_eq!(run(xml), (xml.to_string(), None));
    }
}
