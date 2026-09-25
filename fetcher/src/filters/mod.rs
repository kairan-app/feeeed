pub mod atom_namespace_fixer;
pub mod html_entity_fixer;
pub mod relative_url_resolver;

use serde_json::{Map, Value};

/// XML 文字列に対してかけるフィルタ。適用したときだけ Some を返す。
pub trait PreParseFilter {
    fn name(&self) -> &'static str;
    fn apply(&self, xml: &str) -> Option<(String, Value)>;
}

/// Ruby の FeedNormalizer::PRE_PARSE_FILTERS と同じ順番でかける。
pub fn apply_pre_parse(xml: String) -> (String, Vec<String>, Map<String, Value>) {
    let filters: [&dyn PreParseFilter; 2] = [
        &html_entity_fixer::HtmlEntityFixer,
        &atom_namespace_fixer::AtomNamespaceFixer,
    ];
    let mut current = xml;
    let mut applied = Vec::new();
    let mut details = Map::new();
    for filter in filters {
        if let Some((fixed, detail)) = filter.apply(&current) {
            current = fixed;
            applied.push(filter.name().to_string());
            details.insert(filter.name().to_string(), detail);
        }
    }
    (current, applied, details)
}
