//! WHATWG の名前付き文字参照の表。Rails と同じ JSON をリポジトリから埋め込む。

use std::collections::HashMap;
use std::sync::LazyLock;

static TABLE: LazyLock<HashMap<String, String>> = LazyLock::new(|| {
    serde_json::from_str(include_str!(
        "../../../app/services/feed_filters/data/html_entities.json"
    ))
    .expect("html_entities.json は名前 → 文字列の JSON")
});

pub fn lookup(name: &str) -> Option<&'static str> {
    TABLE.get(name).map(String::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn looks_up_by_name_without_ampersand_and_semicolon() {
        assert_eq!(lookup("nbsp"), Some("\u{a0}"));
        assert_eq!(lookup("copy"), Some("©"));
        assert_eq!(lookup("nbsp;"), None);
    }
}
