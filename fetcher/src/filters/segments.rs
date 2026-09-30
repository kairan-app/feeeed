//! XML 文字列を「書き換えてよい部分」と「CDATA・コメント・処理命令・DOCTYPE」に分け、
//! 書き換えてよい部分だけを変換してつなぎ直す。Ruby 版 (FeedFilters::PreParse::XmlSegments) と同じ正規表現。

use std::sync::LazyLock;

use regex::Regex;

static PROTECTED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|<!DOCTYPE[^\[>]*(?:\[.*?\])?[ \t\r\n]*>",
    )
    .unwrap()
});

pub fn map_unprotected(xml: &str, mut f: impl FnMut(&str) -> String) -> String {
    let mut out = String::with_capacity(xml.len());
    let mut pos = 0;
    for m in PROTECTED.find_iter(xml) {
        out.push_str(&f(&xml[pos..m.start()]));
        out.push_str(m.as_str());
        pos = m.end();
    }
    out.push_str(&f(&xml[pos..]));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn upcase_outside(xml: &str) -> String {
        map_unprotected(xml, |t| t.to_uppercase())
    }

    #[test]
    fn protected_sections_are_left_as_is() {
        let xml = r#"<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x "y">]><a>b<![CDATA[c & d]]>e<!-- f --></a>"#;
        assert_eq!(
            upcase_outside(xml),
            r#"<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x "y">]><A>B<![CDATA[c & d]]>E<!-- f --></A>"#
        );
    }

    #[test]
    fn whole_text_without_sections() {
        assert_eq!(upcase_outside("<a>b</a>"), "<A>B</A>");
    }

    #[test]
    fn unterminated_cdata_is_rewritable() {
        assert_eq!(upcase_outside("<a><![CDATA[b"), "<A><![CDATA[B");
    }
}
