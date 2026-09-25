use std::fs;
use std::path::{Path, PathBuf};

use fetcher::model::ShapedFeed;
use pretty_assertions::assert_eq;

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata/fixtures")
}

pub fn feed_url_for(dir: &Path, name: &str) -> String {
    let url_path = dir.join(format!("{name}.url"));
    match fs::read_to_string(&url_path) {
        Ok(s) => s.lines().next().unwrap_or_default().trim().to_string(),
        Err(_) => format!("https://example.com/{name}/feed.xml"),
    }
}

fn check(name: &str) {
    let dir = fixtures_dir();
    let body = fs::read(dir.join(format!("{name}.xml"))).unwrap();
    let golden: ShapedFeed =
        serde_json::from_str(&fs::read_to_string(dir.join(format!("{name}.golden.json"))).unwrap())
            .unwrap();
    let mut actual = fetcher::golden_output(&body, &feed_url_for(&dir, name)).unwrap();
    actual.normalize_order();
    assert_eq!(golden, actual, "fixture: {name}");
}

macro_rules! golden_tests {
    ($($name:ident),* $(,)?) => {
        $(
            #[test]
            #[ignore = "Task 6 で有効にする"]
            fn $name() { check(stringify!($name)); }
        )*
    };
}

golden_tests!(
    rss_basic,
    rss_edge,
    itunes_podcast,
    atom_basic,
    atom_https_ns,
    rss_entity_copyright,
    rss_relative_urls,
    youtube,
    google_alerts,
    rss_invalid_utf8,
    rss_undefined_entity,
);
