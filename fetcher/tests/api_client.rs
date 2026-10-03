use std::time::Duration;

use fetcher::api_client::{ApiClient, Delivery};
use fetcher::dispatcher_client::NewGuidQuery;
use fetcher::result::ResultPayload;
use wiremock::matchers::{body_json, header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn client(server: &MockServer) -> ApiClient {
    ApiClient::new(&server.uri(), "tok")
        .unwrap()
        .with_retry_base(Duration::from_millis(1))
}

#[tokio::test]
async fn leases_sends_max_with_the_token() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases"))
        .and(header("authorization", "Bearer tok"))
        .and(body_json(serde_json::json!({ "max": 3 })))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "leases": [{ "channel_id": 7, "feed_url": "https://e/f.xml", "site_url": null, "use_proxy": false }],
            "proxy_required_domains": ["p.example"]
        })))
        .mount(&server)
        .await;

    let batch = client(&server).leases(3).await.unwrap();
    assert_eq!(batch.leases[0].channel_id, 7);
    assert_eq!(batch.proxy_required_domains, vec!["p.example"]);
}

#[tokio::test]
async fn new_flags_posts_entries_to_guid_lookups() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/channels/7/guid_lookups"))
        .and(body_json(
            serde_json::json!({ "entries": [{ "entry_id": "a", "url": null }] }),
        ))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(serde_json::json!({ "new": [true] })),
        )
        .mount(&server)
        .await;

    let flags = client(&server)
        .new_flags(
            7,
            &[NewGuidQuery {
                entry_id: Some("a".into()),
                url: None,
            }],
        )
        .await
        .unwrap();
    assert_eq!(flags, vec![true]);
}

#[tokio::test]
async fn send_result_retries_server_errors() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(ResponseTemplate::new(503))
        .up_to_n_times(2)
        .with_priority(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({ "created": 0, "skipped": 0 })),
        )
        .with_priority(2)
        .mount(&server)
        .await;

    let d = client(&server)
        .send_result(7, &ResultPayload::failed("timeout", "t"))
        .await
        .unwrap();
    assert_eq!(d, Delivery::Accepted);
    assert_eq!(server.received_requests().await.unwrap().len(), 3);
}

#[tokio::test]
async fn send_result_treats_202_as_accepted() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(
            ResponseTemplate::new(202).set_body_json(serde_json::json!({ "queued": 300 })),
        )
        .mount(&server)
        .await;

    let d = client(&server)
        .send_result(7, &ResultPayload::failed("timeout", "t"))
        .await
        .unwrap();
    assert_eq!(d, Delivery::Accepted);
}

#[tokio::test]
async fn send_result_gives_up_on_conflict_without_retrying() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(ResponseTemplate::new(409))
        .mount(&server)
        .await;

    let d = client(&server)
        .send_result(7, &ResultPayload::failed("timeout", "t"))
        .await
        .unwrap();
    assert_eq!(d, Delivery::LeaseLost);
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn send_result_does_not_retry_other_client_errors() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(ResponseTemplate::new(422))
        .mount(&server)
        .await;

    assert!(
        client(&server)
            .send_result(7, &ResultPayload::failed("timeout", "t"))
            .await
            .is_err()
    );
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn send_result_fails_after_exhausting_retries() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(ResponseTemplate::new(500))
        .mount(&server)
        .await;

    assert!(
        client(&server)
            .send_result(7, &ResultPayload::failed("timeout", "t"))
            .await
            .is_err()
    );
    assert_eq!(server.received_requests().await.unwrap().len(), 6);
}
