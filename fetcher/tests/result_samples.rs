//! Rust と Rails の間の result の形を固定する。同じファイルを Rails の
//! test/services/fetch_result_contract_test.rb が読み、golden どおりの item ができることを確かめる。
//! 形を変えたら `UPDATE_RESULT_SAMPLES=1 cargo test --test result_samples` で作り直し、Rails 側のテストも通すこと

use std::fs;
use std::path::{Path, PathBuf};

use fetcher::result::{ResultPayload, sample_payload};
use pretty_assertions::assert_eq;

const SAMPLES: &[&str] = &[
    "rss_basic",
    "itunes_podcast",
    "atom_basic",
    "rss_image_url_noise",
];

fn testdata() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata")
}

fn feed_url_for(name: &str) -> String {
    match fs::read_to_string(testdata().join("fixtures").join(format!("{name}.url"))) {
        Ok(s) => s.lines().next().unwrap_or_default().trim().to_string(),
        Err(_) => format!("https://example.com/{name}/feed.xml"),
    }
}

#[test]
fn result_samples_match_the_payload_built_from_fixtures() {
    let update = std::env::var_os("UPDATE_RESULT_SAMPLES").is_some();
    fs::create_dir_all(testdata().join("result")).unwrap();
    for name in SAMPLES {
        let body = fs::read(testdata().join("fixtures").join(format!("{name}.xml"))).unwrap();
        let actual = sample_payload(&body, &feed_url_for(name)).unwrap();
        let path = testdata().join("result").join(format!("{name}.json"));
        if update {
            fs::write(&path, serde_json::to_string_pretty(&actual).unwrap() + "\n").unwrap();
        }
        let expected: ResultPayload =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(expected, actual, "sample: {name}");
    }
}
