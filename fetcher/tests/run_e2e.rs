use std::time::Duration;

use fetcher::http::{DEFAULT_MAX_BODY_BYTES, HttpConfig};
use fetcher::run::{RunOptions, run};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

fn http_config() -> HttpConfig {
    HttpConfig {
        user_agent: "Faraday v2.14.3".into(),
        connect_timeout: Duration::from_secs(2),
        total_timeout: Duration::from_secs(5),
        proxy: None,
        min_host_interval: Duration::from_millis(0),
        max_body_bytes: DEFAULT_MAX_BODY_BYTES,
        // モックサーバは 127.0.0.1 で動くので、テストでだけ許可する
        allow_private_addresses: true,
    }
}

fn options(api: &MockServer, deadline: Duration) -> RunOptions {
    RunOptions {
        api_url: api.uri(),
        token: "tok".into(),
        concurrency: 2,
        idle_wait: Duration::from_millis(50),
        busy_wait: Duration::from_millis(50),
        deadline,
        result_retry_base: Duration::from_millis(1),
        http: http_config(),
    }
}

fn rss(base: &str) -> String {
    format!(
        r#"<rss version="2.0"><channel><title>T</title><link>{base}/</link><description>d</description>
        <item><title>A</title><link>{base}/a</link><guid isPermaLink="false">ga</guid><pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate></item>
        <item><title>B</title><link>{base}/b</link><guid isPermaLink="false">gb</guid><pubDate>Wed, 24 Sep 2026 01:00:00 +0000</pubDate></item>
        </channel></rss>"#
    )
}

/// 1回目の貸し出しで lease を1つ返し、2回目以降は空を返す
async fn mount_one_lease(api: &MockServer, feed_url: String) {
    Mock::given(method("POST"))
        .and(path("/fetcher/leases"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "leases": [{ "channel_id": 1, "feed_url": feed_url, "site_url": null, "use_proxy": false }],
            "proxy_required_domains": []
        })))
        .up_to_n_times(1)
        .with_priority(1)
        .mount(api)
        .await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({ "leases": [], "proxy_required_domains": [] })),
        )
        .with_priority(2)
        .mount(api)
        .await;
}

async fn result_bodies(api: &MockServer) -> Vec<serde_json::Value> {
    api.received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r: &&Request| r.url.path() == "/fetcher/leases/1/result")
        .map(|r| serde_json::from_slice(&r.body).unwrap())
        .collect()
}

/// result が届くまで待ってから止める
async fn shutdown_after_result(api: &MockServer) {
    for _ in 0..200 {
        if !result_bodies(api).await.is_empty() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("result was never sent");
}

#[tokio::test]
async fn sends_only_new_entries_with_ogp_and_latest_guids() {
    let site = MockServer::start().await;
    Mock::given(path("/feed.xml"))
        .respond_with(ResponseTemplate::new(200).set_body_string(rss(&site.uri())))
        .mount(&site)
        .await;
    // サイトとエントリーの OGP
    Mock::given(path("/"))
        .respond_with(ResponseTemplate::new(200).set_body_string(
            r#"<html><head><meta property="og:image" content="https://img.example/site.png"></head></html>"#,
        ))
        .mount(&site)
        .await;
    Mock::given(path("/b"))
        .respond_with(ResponseTemplate::new(200).set_body_string(
            r#"<html><head><meta property="og:image" content="https://img.example/b.png"></head></html>"#,
        ))
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/feed.xml", site.uri())).await;
    Mock::given(method("POST"))
        .and(path("/fetcher/channels/1/guid_lookups"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(serde_json::json!({ "new": [false, true] })),
        )
        .mount(&api)
        .await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/1/result"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({ "created": 1, "skipped": 0 })),
        )
        .mount(&api)
        .await;

    run(
        options(&api, Duration::from_secs(30)),
        shutdown_after_result(&api),
    )
    .await
    .unwrap();

    let bodies = result_bodies(&api).await;
    assert_eq!(bodies.len(), 1);
    let body = &bodies[0];
    assert_eq!(body["fetched"], true);
    assert_eq!(body["final_url"], serde_json::Value::Null);
    assert_eq!(body["channel"]["title"], "T");
    assert_eq!(body["channel"]["image_url"], "https://img.example/site.png");
    let entries = body["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["guid"], "gb");
    assert_eq!(entries[0]["image_url"], "https://img.example/b.png");
    assert_eq!(entries[0]["data"]["entry_id"], "gb");
    assert_eq!(
        body["latest_guids"],
        serde_json::json!([
            "ga",
            format!("{}/a", site.uri()),
            "gb",
            format!("{}/b", site.uri())
        ])
    );
}

#[tokio::test]
async fn reports_the_redirected_url_and_uses_it_for_the_channel() {
    let site = MockServer::start().await;
    Mock::given(path("/old.xml"))
        .respond_with(
            ResponseTemplate::new(301).insert_header("location", format!("{}/new.xml", site.uri())),
        )
        .mount(&site)
        .await;
    Mock::given(path("/new.xml"))
        .respond_with(ResponseTemplate::new(200).set_body_string(rss(&site.uri())))
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/old.xml", site.uri())).await;
    Mock::given(method("POST"))
        .and(path("/fetcher/channels/1/guid_lookups"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(serde_json::json!({ "new": [false, false] })),
        )
        .mount(&api)
        .await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/1/result"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({ "created": 0, "skipped": 0 })),
        )
        .mount(&api)
        .await;

    run(
        options(&api, Duration::from_secs(30)),
        shutdown_after_result(&api),
    )
    .await
    .unwrap();

    let body = &result_bodies(&api).await[0];
    assert_eq!(body["final_url"], format!("{}/new.xml", site.uri()));
    assert!(body["entries"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn sends_a_fetch_error_as_a_failed_result() {
    let site = MockServer::start().await;
    Mock::given(path("/gone.xml"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/gone.xml", site.uri())).await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/1/result"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({ "created": 0, "skipped": 0 })),
        )
        .mount(&api)
        .await;

    run(
        options(&api, Duration::from_secs(30)),
        shutdown_after_result(&api),
    )
    .await
    .unwrap();

    let body = &result_bodies(&api).await[0];
    assert_eq!(body["fetched"], false);
    assert_eq!(body["error"]["kind"], "http_status");
}

#[tokio::test]
async fn gives_up_at_the_deadline() {
    let site = MockServer::start().await;
    Mock::given(path("/slow.xml"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string(rss("https://e.example"))
                .set_delay(Duration::from_secs(3)),
        )
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/slow.xml", site.uri())).await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/1/result"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({ "created": 0, "skipped": 0 })),
        )
        .mount(&api)
        .await;

    run(
        options(&api, Duration::from_millis(200)),
        shutdown_after_result(&api),
    )
    .await
    .unwrap();

    let body = &result_bodies(&api).await[0];
    assert_eq!(body["fetched"], false);
    assert_eq!(body["error"]["kind"], "deadline");
}

#[tokio::test]
async fn finishes_the_in_flight_channel_on_shutdown_and_stops_leasing() {
    let site = MockServer::start().await;
    Mock::given(path("/feed.xml"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string(rss(&site.uri()))
                .set_delay(Duration::from_millis(300)),
        )
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/feed.xml", site.uri())).await;
    Mock::given(method("POST"))
        .and(path("/fetcher/channels/1/guid_lookups"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(serde_json::json!({ "new": [false, false] })),
        )
        .mount(&api)
        .await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/1/result"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({ "created": 0, "skipped": 0 })),
        )
        .mount(&api)
        .await;

    // 1回目の貸し出しは頼んだ数 (2) より少なく、取得中のチャンネルがあるので、次を頼む前に busy_wait だけ待つ。
    // その待ちの途中、取得の応答 (300ms) を待っている間に止める
    let mut opts = options(&api, Duration::from_secs(30));
    opts.idle_wait = Duration::from_secs(10);
    opts.busy_wait = Duration::from_secs(10);
    run(opts, tokio::time::sleep(Duration::from_millis(100)))
        .await
        .unwrap();

    assert_eq!(
        result_bodies(&api).await.len(),
        1,
        "in-flight result must still be sent"
    );
    let leases = api
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/fetcher/leases")
        .count();
    assert_eq!(leases, 1, "no new lease after shutdown");
}

#[tokio::test]
async fn skips_slow_entry_ogp_to_send_new_entries_within_the_deadline() {
    let site = MockServer::start().await;
    Mock::given(path("/feed.xml"))
        .respond_with(ResponseTemplate::new(200).set_body_string(rss(&site.uri())))
        .mount(&site)
        .await;
    // 記事のページが OGP の持ち時間 (deadline 2s の 3/5 = 1.2s) より遅い
    Mock::given(path("/b"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string(
                    r#"<html><head><meta property="og:image" content="https://img.example/b.png"></head></html>"#,
                )
                .set_delay(Duration::from_secs(3)),
        )
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/feed.xml", site.uri())).await;
    Mock::given(method("POST"))
        .and(path("/fetcher/channels/1/guid_lookups"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(serde_json::json!({ "new": [false, true] })),
        )
        .mount(&api)
        .await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/1/result"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({ "created": 1, "skipped": 0 })),
        )
        .mount(&api)
        .await;

    run(
        options(&api, Duration::from_secs(2)),
        shutdown_after_result(&api),
    )
    .await
    .unwrap();

    let body = &result_bodies(&api).await[0];
    assert_eq!(body["fetched"], true, "{body}");
    let entries = body["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["guid"], "gb");
    assert_eq!(entries[0]["image_url"], serde_json::Value::Null);
}

#[tokio::test]
async fn asks_again_soon_after_a_short_batch_while_channels_are_in_flight() {
    let site = MockServer::start().await;
    Mock::given(path("/feed.xml"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string(rss(&site.uri()))
                .set_delay(Duration::from_secs(2)),
        )
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/feed.xml", site.uri())).await;

    // 1回目の貸し出しは頼んだ数 (2) より少ないが、取得中のチャンネルがあるので idle_wait (10s) ではなく
    // busy_wait (50ms) だけ待って、また頼む
    let mut opts = options(&api, Duration::from_secs(30));
    opts.idle_wait = Duration::from_secs(10);
    opts.busy_wait = Duration::from_millis(50);
    tokio::time::timeout(
        Duration::from_secs(5),
        run(opts, tokio::time::sleep(Duration::from_millis(500))),
    )
    .await
    .expect("run should stop after the in-flight channel")
    .unwrap();

    let leases = api
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/fetcher/leases")
        .count();
    assert!(
        leases >= 2,
        "should ask again within busy_wait, got {leases}"
    );
}
