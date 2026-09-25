use std::time::Duration;

use fetcher::http::HttpConfig;
use fetcher::shadow::{ShadowOptions, run_shadow};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

#[tokio::test]
async fn shadow_writes_one_report_line_per_channel() {
    let feeds = MockServer::start().await;
    let rss = r#"<rss version="2.0"><channel><title>T</title><link>https://e.example/</link><description>d</description>
        <item><title>A</title><link>https://e.example/a</link><guid isPermaLink="false">ga</guid><pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate></item>
        <item><title>B</title><link>https://e.example/b</link><guid isPermaLink="false">gb</guid><pubDate>Wed, 24 Sep 2026 01:00:00 +0000</pubDate></item>
    </channel></rss>"#;
    Mock::given(path("/ok.xml"))
        .respond_with(ResponseTemplate::new(200).set_body_string(rss))
        .mount(&feeds)
        .await;
    Mock::given(path("/gone.xml"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&feeds)
        .await;

    let api = MockServer::start().await;
    let batch = serde_json::json!({
        "channels": [
            { "channel_id": 1, "feed_url": format!("{}/ok.xml", feeds.uri()), "site_url": "https://e.example/", "use_proxy": false,
              "stored": { "title": "T", "description": "d", "site_url": "https://e.example/", "image_url": null } },
            { "channel_id": 2, "feed_url": format!("{}/gone.xml", feeds.uri()), "site_url": null, "use_proxy": false,
              "stored": { "title": "G", "description": null, "site_url": null, "image_url": null } }
        ],
        "proxy_required_domains": []
    });
    Mock::given(method("GET"))
        .and(path("/shadow/channels"))
        .respond_with(ResponseTemplate::new(200).set_body_json(batch))
        .mount(&api)
        .await;
    Mock::given(method("POST"))
        .and(path("/channels/1/new-guids"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(serde_json::json!({ "new": [false, true] })),
        )
        .mount(&api)
        .await;
    Mock::given(method("POST"))
        .and(path("/shadow/channels/1/items"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "items": [
            { "guid": "ga", "title": "A (old)", "url": "https://e.example/a", "image_url": null, "published_at": "2026-09-24T00:00:00Z",
              "data": { "summary": null, "itunes_subtitle": null, "enclosure_url": null, "enclosure_type": null } }
        ] })))
        .mount(&api)
        .await;

    let dir = std::env::temp_dir().join(format!("shadow-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = dir.join("report.jsonl");
    run_shadow(ShadowOptions {
        api_url: api.uri(),
        token: "t".into(),
        max: 10,
        order: "priority".into(),
        concurrency: 4,
        out: out.clone(),
        http: HttpConfig {
            user_agent: "Faraday v2.14.3".into(),
            connect_timeout: Duration::from_secs(2),
            total_timeout: Duration::from_secs(5),
            proxy: None,
            min_host_interval: Duration::from_millis(0),
        },
    })
    .await
    .unwrap();

    let lines: Vec<serde_json::Value> = std::fs::read_to_string(&out)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(lines.len(), 2);
    let ok = lines.iter().find(|l| l["channel_id"] == 1).unwrap();
    assert_eq!(ok["status"], "ok");
    assert_eq!(ok["entries_in_feed"], 2);
    assert_eq!(ok["new_entries"], 1);
    assert_eq!(ok["entries_compared"], 1);
    assert_eq!(ok["diffs"][0]["field"], "title");
    let gone = lines.iter().find(|l| l["channel_id"] == 2).unwrap();
    assert_eq!(gone["status"], "fetch_error");
    assert_eq!(gone["error"], "http_status: HTTP status 404");
}
