use std::collections::HashSet;

use scraper::{Html, Selector};

use crate::encoding::to_utf8_dropping_invalid;
use crate::http::HttpClient;
use crate::shape::channel::Ogp;

fn meta_content(doc: &Html, key: &str) -> Option<String> {
    let selector = Selector::parse("meta").unwrap();
    doc.select(&selector)
        .find(|m| m.value().attrs().any(|(_, v)| v == key))
        .and_then(|m| m.value().attr("content").map(str::to_string))
}

pub fn extract_ogp(html: &str, page_url: &str) -> Ogp {
    let doc = Html::parse_document(html);
    let title_selector = Selector::parse("title").unwrap();
    let title: String = doc.select(&title_selector).flat_map(|t| t.text()).collect();
    let mut image = meta_content(&doc, "og:image");
    if let Some(img) = image.as_deref().filter(|i| i.starts_with('/')) {
        image = url::Url::parse(page_url)
            .and_then(|b| b.join(img))
            .map(|u| u.to_string())
            .ok();
    }
    Ogp {
        title: if title.is_empty() { None } else { Some(title) },
        description: meta_content(&doc, "og:description"),
        image,
    }
}

pub async fn fetch_ogp(
    client: &HttpClient,
    url: &str,
    proxy_domains: &HashSet<String>,
) -> Option<Ogp> {
    let host = url::Url::parse(url).ok()?.host_str()?.to_ascii_lowercase();
    let res = client
        .get_page(url, proxy_domains.contains(&host))
        .await
        .ok()?;
    Some(extract_ogp(&to_utf8_dropping_invalid(&res.body), url))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_like_open_graph_rb() {
        let html = r#"<html><head><title>Page</title>
            <meta name="og:description" content="desc">
            <meta property="og:image" content="/img/a.png">
            <meta property="og:image" content="/img/b.png">
        </head></html>"#;
        let ogp = extract_ogp(html, "https://example.com/post/1");
        assert_eq!(ogp.title.as_deref(), Some("Page"));
        assert_eq!(ogp.description.as_deref(), Some("desc"));
        assert_eq!(ogp.image.as_deref(), Some("https://example.com/img/a.png"));
    }

    #[test]
    fn keeps_non_slash_relative_image_as_is() {
        let html = r#"<meta property="og:image" content="img/a.png">"#;
        assert_eq!(
            extract_ogp(html, "https://example.com/post/1")
                .image
                .as_deref(),
            Some("img/a.png")
        );
    }
}
