//! Rails の挙動に合わせるための、Ruby 互換の小さな関数たち。

use std::sync::LazyLock;

use regex::Regex;

pub const URL_MAX_LENGTH: usize = 4096;

/// Ruby の `blank?` (空文字、または Unicode の空白だけ)
pub fn is_blank(s: &str) -> bool {
    s.chars().all(char::is_whitespace)
}

/// Ruby の `presence`
pub fn opt_presence(s: Option<&str>) -> Option<&str> {
    s.filter(|v| !is_blank(v))
}

/// Ruby の `String#strip` (NUL と ASCII の空白だけを除く)
pub fn ruby_strip(s: &str) -> &str {
    s.trim_matches(|c| matches!(c, '\0' | '\t' | '\n' | '\x0b' | '\x0c' | '\r' | ' '))
}

// Ruby の URI.regexp(%w[http https]) は位置を固定しない部分一致なので、
// 「http: か https: の後に URI の文字が1つ以上続く箇所があるか」で近似する。
static URI_HTTP: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)https?:[A-Za-z0-9\-_.!~*'();/?:@&=+$,%\[\]#]").unwrap());

pub fn matches_uri_http(s: &str) -> bool {
    URI_HTTP.is_match(s)
}

/// `validates_url_http_format_of` 相当 (nil は呼び出し側で許可する)
pub fn valid_url_column(s: &str) -> bool {
    matches_uri_http(s) && s.chars().count() <= URL_MAX_LENGTH
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blank_matches_ruby() {
        assert!(is_blank(""));
        assert!(is_blank(" \t\n"));
        assert!(is_blank("\u{3000}"));
        assert!(!is_blank(" a "));
    }

    #[test]
    fn strip_matches_ruby() {
        assert_eq!(ruby_strip("\0 a b \t\n"), "a b");
        assert_eq!(ruby_strip("\u{3000}a\u{3000}"), "\u{3000}a\u{3000}");
    }

    #[test]
    fn uri_http_is_partial_match_like_ruby() {
        assert!(matches_uri_http("https://example.com/a"));
        assert!(matches_uri_http("see http://example.com"));
        assert!(matches_uri_http("HTTP://EXAMPLE.COM"));
        assert!(!matches_uri_http("javascript:alert(1)"));
        assert!(!matches_uri_http("mailto:someone@example.com"));
        assert!(!matches_uri_http("/relative/path"));
    }

    #[test]
    fn url_column_has_length_limit() {
        let long = format!("https://example.com/{}", "a".repeat(4096));
        assert!(!valid_url_column(&long));
    }
}
