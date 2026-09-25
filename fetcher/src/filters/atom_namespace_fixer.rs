use serde_json::json;

use super::PreParseFilter;

const DOUBLE: &str = r#"xmlns="https://www.w3.org/2005/Atom""#;
const SINGLE: &str = "xmlns='https://www.w3.org/2005/Atom'";

pub struct AtomNamespaceFixer;

impl PreParseFilter for AtomNamespaceFixer {
    fn name(&self) -> &'static str {
        "AtomNamespaceFixer"
    }

    fn apply(&self, xml: &str) -> Option<(String, serde_json::Value)> {
        if !xml.contains(DOUBLE) && !xml.contains(SINGLE) {
            return None;
        }
        let mut modified = xml.to_string();
        let mut original = None;
        if modified.contains(DOUBLE) {
            original = Some(DOUBLE);
            modified = modified.replace(DOUBLE, r#"xmlns="http://www.w3.org/2005/Atom""#);
        }
        if modified.contains(SINGLE) {
            original = Some(SINGLE);
            modified = modified.replace(SINGLE, "xmlns='http://www.w3.org/2005/Atom'");
        }
        let original = original.unwrap();
        Some((
            modified,
            json!({
                "fixed": "Atom namespace URL protocol",
                "original_namespace": original,
                "corrected_namespace": original.replace("https:", "http:"),
            }),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::filters::PreParseFilter;

    #[test]
    fn fixes_https_namespace_with_both_quotes() {
        let (fixed, details) = AtomNamespaceFixer
            .apply(r#"<feed xmlns="https://www.w3.org/2005/Atom">"#)
            .unwrap();
        assert_eq!(fixed, r#"<feed xmlns="http://www.w3.org/2005/Atom">"#);
        assert_eq!(
            details["original_namespace"],
            r#"xmlns="https://www.w3.org/2005/Atom""#
        );

        let (fixed, _) = AtomNamespaceFixer
            .apply("<feed xmlns='https://www.w3.org/2005/Atom'>")
            .unwrap();
        assert_eq!(fixed, "<feed xmlns='http://www.w3.org/2005/Atom'>");
    }

    #[test]
    fn not_applicable_for_correct_namespace() {
        assert!(
            AtomNamespaceFixer
                .apply(r#"<feed xmlns="http://www.w3.org/2005/Atom">"#)
                .is_none()
        );
    }
}
