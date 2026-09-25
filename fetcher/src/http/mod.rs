pub mod address_guard;
pub mod host_gate;

use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{COOKIE, LOCATION, SET_COOKIE};
use reqwest::redirect::Policy;

use address_guard::{BlockedAddressError, PublicOnlyResolver, is_blocked_ip};
use host_gate::HostGate;

/// Faraday の follow_redirects の既定と同じ (3回まで追い、4回目で失敗)。
const MAX_REDIRECTS: usize = 3;

/// 応答本文の上限。これを超えるフィード・ページは読み切らずに打ち切る。
pub const DEFAULT_MAX_BODY_BYTES: usize = 20 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct ProxyConfig {
    pub url: String,
    pub secret: String,
}

#[derive(Debug, Clone)]
pub struct HttpConfig {
    pub user_agent: String,
    pub connect_timeout: Duration,
    pub total_timeout: Duration,
    pub proxy: Option<ProxyConfig>,
    pub min_host_interval: Duration,
    /// 応答本文の上限 (バイト)。超えたら `FetchError::TooLarge`
    pub max_body_bytes: usize,
    /// ループバック・プライベートアドレスなどへの接続を許すか。CLI では常に false
    /// (内部ネットワークへの取得を防ぐ)。ローカルのモックサーバに向けるテストだけが true にする
    pub allow_private_addresses: bool,
}

#[derive(Debug, Clone)]
pub struct FetchResponse {
    pub body: Vec<u8>,
    pub final_url: String,
    pub redirected: bool,
    pub via_proxy: bool,
    pub register_proxy_domain: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum FetchError {
    #[error("HTTP status {0}")]
    Status(u16),
    #[error("timeout")]
    Timeout,
    #[error("connect: {0}")]
    Connect(String),
    #[error("too many redirects")]
    TooManyRedirects,
    #[error("refused to connect to a non-public address: {0}")]
    BlockedAddress(String),
    #[error("response body exceeds {0} bytes")]
    TooLarge(usize),
    #[error("{0}")]
    Other(String),
}

impl FetchError {
    pub fn kind(&self) -> &'static str {
        match self {
            FetchError::Status(_) => "http_status",
            FetchError::Timeout => "timeout",
            FetchError::Connect(_) => "connect",
            FetchError::TooManyRedirects => "too_many_redirects",
            FetchError::BlockedAddress(_) => "blocked_address",
            FetchError::TooLarge(_) => "too_large",
            FetchError::Other(_) => "other",
        }
    }

    fn from_reqwest(e: reqwest::Error) -> Self {
        let mut source = std::error::Error::source(&e);
        while let Some(inner) = source {
            if let Some(blocked) = inner.downcast_ref::<BlockedAddressError>() {
                return FetchError::BlockedAddress(blocked.host.clone());
            }
            source = inner.source();
        }
        if e.is_timeout() {
            FetchError::Timeout
        } else if e.is_connect() {
            FetchError::Connect(e.to_string())
        } else {
            FetchError::Other(e.to_string())
        }
    }

    /// このエラーのときに proxy での再試行を試みるべきか (Httpc::PROXY_TRIGGERING_ERRORS /
    /// PROXY_TRIGGERING_STATUSES 相当。403 はフィード取得のときだけ対象)。
    fn triggers_proxy(&self, is_feed: bool) -> bool {
        matches!(self, FetchError::Timeout | FetchError::Connect(_))
            || (is_feed && matches!(self, FetchError::Status(403)))
    }
}

pub struct HttpClient {
    client: reqwest::Client,
    config: HttpConfig,
    gate: HostGate,
    /// テスト用: 取得先の検査で、この1つのアドレスだけは例外として通す
    #[cfg(test)]
    test_allowed_origin: Option<std::net::SocketAddr>,
}

impl HttpClient {
    pub fn new(config: HttpConfig) -> anyhow::Result<Self> {
        let mut builder = reqwest::Client::builder()
            .user_agent(config.user_agent.clone())
            .connect_timeout(config.connect_timeout)
            .timeout(config.total_timeout)
            .redirect(Policy::none());
        if !config.allow_private_addresses {
            // 環境変数の HTTP(S)_PROXY で取得先の検査がすり抜けないよう、システムのプロキシも使わない
            builder = builder
                .dns_resolver(Arc::new(PublicOnlyResolver))
                .no_proxy();
        }
        let client = builder.build()?;
        let gate = HostGate::new(config.min_host_interval);
        Ok(Self {
            client,
            config,
            gate,
            #[cfg(test)]
            test_allowed_origin: None,
        })
    }

    /// IP リテラルのホストは名前解決を通らないので、接続の前にここで調べる
    /// (ホスト名のほうは PublicOnlyResolver が調べる)。
    fn check_literal_host(&self, url: &url::Url) -> Result<(), FetchError> {
        if self.config.allow_private_addresses {
            return Ok(());
        }
        let ip = match url.host() {
            Some(url::Host::Ipv4(ip)) => std::net::IpAddr::V4(ip),
            Some(url::Host::Ipv6(ip)) => std::net::IpAddr::V6(ip),
            _ => return Ok(()),
        };
        #[cfg(test)]
        if let Some(allowed) = self.test_allowed_origin
            && allowed.ip() == ip
            && url.port_or_known_default() == Some(allowed.port())
        {
            return Ok(());
        }
        if is_blocked_ip(ip) {
            return Err(FetchError::BlockedAddress(ip.to_string()));
        }
        Ok(())
    }

    /// 本文を少しずつ読み、`max_body_bytes` を超えたところで打ち切る
    async fn read_body(&self, mut res: reqwest::Response) -> Result<Vec<u8>, FetchError> {
        let limit = self.config.max_body_bytes;
        if res.content_length().is_some_and(|len| len > limit as u64) {
            return Err(FetchError::TooLarge(limit));
        }
        let mut body = Vec::new();
        while let Some(chunk) = res.chunk().await.map_err(FetchError::from_reqwest)? {
            if body.len() + chunk.len() > limit {
                return Err(FetchError::TooLarge(limit));
            }
            body.extend_from_slice(&chunk);
        }
        Ok(body)
    }

    /// Httpc.get_with_redirect_info 相当 (フィード用。403 でも proxy で再試行)
    pub async fn get_feed(&self, url: &str, use_proxy: bool) -> Result<FetchResponse, FetchError> {
        self.get(url, use_proxy, true).await
    }

    /// Httpc.get 相当 (OGP 用。proxy が要るドメインかどうかは呼び出し側が渡す。403 では再試行しない)
    pub async fn get_page(&self, url: &str, use_proxy: bool) -> Result<FetchResponse, FetchError> {
        self.get(url, use_proxy, false).await
    }

    async fn get(
        &self,
        url: &str,
        use_proxy: bool,
        is_feed: bool,
    ) -> Result<FetchResponse, FetchError> {
        if use_proxy && self.config.proxy.is_some() {
            return self.via_proxy(url, false).await;
        }
        match self.direct(url).await {
            Ok(res) => Ok(res),
            Err(e) if e.triggers_proxy(is_feed) && self.config.proxy.is_some() => {
                tracing::info!(url, error = %e, "direct request failed, retrying via proxy");
                self.via_proxy(url, true).await
            }
            Err(e) => Err(e),
        }
    }

    /// リダイレクトを自前で追う (最大 MAX_REDIRECTS 回)。Cookie はこの取得の中だけで
    /// 引き継ぐ (Faraday で毎回新しい cookie_jar を作っているのと同じ)。Cookie は
    /// それを受け取ったホストにだけ送り返す (別ホストへのリダイレクト先には送らない)。
    /// ホストごとの門番と取得先アドレスの検査は各リダイレクト先にも適用する。
    async fn direct(&self, url: &str) -> Result<FetchResponse, FetchError> {
        let mut current = url::Url::parse(url).map_err(|e| FetchError::Other(e.to_string()))?;
        // (Cookie を受け取ったホスト (小文字), "name=value")
        let mut cookies: Vec<(String, String)> = Vec::new();
        for hops in 0..=MAX_REDIRECTS {
            self.check_literal_host(&current)?;
            let host = current.host_str().unwrap_or_default().to_ascii_lowercase();
            let _permit = self.gate.acquire(&host).await;
            let mut req = self.client.get(current.clone());
            let cookie_header = cookies
                .iter()
                .filter(|(h, _)| *h == host)
                .map(|(_, pair)| pair.as_str())
                .collect::<Vec<_>>()
                .join("; ");
            if !cookie_header.is_empty() {
                req = req.header(COOKIE, cookie_header);
            }
            let res = req.send().await.map_err(FetchError::from_reqwest)?;
            for value in res.headers().get_all(SET_COOKIE) {
                if let Some(pair) = value.to_str().ok().and_then(|v| v.split(';').next()) {
                    cookies.push((host.clone(), pair.trim().to_string()));
                }
            }
            let status = res.status();
            if status.is_redirection() {
                let location = res
                    .headers()
                    .get(LOCATION)
                    .and_then(|v| v.to_str().ok())
                    .ok_or_else(|| FetchError::Other("redirect without location".into()))?;
                current = current
                    .join(location)
                    .map_err(|e| FetchError::Other(e.to_string()))?;
                continue;
            }
            if !status.is_success() {
                return Err(FetchError::Status(status.as_u16()));
            }
            let final_url = current.to_string();
            let body = self.read_body(res).await?;
            return Ok(FetchResponse {
                body,
                // url::Url の正規化 (末尾の / や host の小文字化) だけで「リダイレクトした」にしない
                redirected: hops > 0 && final_url != url,
                final_url,
                via_proxy: false,
                register_proxy_domain: false,
            });
        }
        Err(FetchError::TooManyRedirects)
    }

    /// proxy 経由の取得 (Cloudflare Worker)。proxy 側が別の IP から取りにいくため、
    /// ホストごとの門番は通さない。`is_retry` は直接取得が失敗しての再試行かどうかで、
    /// 2xx なら呼び出し元に `register_proxy_domain: true` を返す。
    async fn via_proxy(&self, url: &str, is_retry: bool) -> Result<FetchResponse, FetchError> {
        let proxy = self.config.proxy.as_ref().expect("proxy is configured");
        let res = self
            .client
            .get(format!("{}/", proxy.url.trim_end_matches('/')))
            .header("X-Proxy-Secret", &proxy.secret)
            .header("X-Target-URL", url)
            .send()
            .await
            .map_err(FetchError::from_reqwest)?;
        let status = res.status();
        if !status.is_success() {
            return Err(FetchError::Status(status.as_u16()));
        }
        let final_url = res
            .headers()
            .get("X-Original-URL")
            .and_then(|v| v.to_str().ok())
            .unwrap_or(url)
            .to_string();
        let body = self.read_body(res).await?;
        Ok(FetchResponse {
            body,
            redirected: final_url != url,
            final_url,
            via_proxy: true,
            register_proxy_domain: is_retry,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn config(proxy: Option<ProxyConfig>) -> HttpConfig {
        HttpConfig {
            user_agent: "Faraday v2.14.3".into(),
            connect_timeout: Duration::from_secs(2),
            total_timeout: Duration::from_millis(500),
            proxy,
            min_host_interval: Duration::from_millis(0),
            max_body_bytes: DEFAULT_MAX_BODY_BYTES,
            allow_private_addresses: true,
        }
    }

    fn blocking_config() -> HttpConfig {
        HttpConfig {
            allow_private_addresses: false,
            ..config(None)
        }
    }

    #[tokio::test]
    async fn follows_redirects_and_reports_final_url() {
        let server = MockServer::start().await;
        Mock::given(path("/old"))
            .respond_with(ResponseTemplate::new(301).insert_header("Location", "/new"))
            .mount(&server)
            .await;
        Mock::given(path("/new"))
            .and(header("User-Agent", "Faraday v2.14.3"))
            .respond_with(ResponseTemplate::new(200).set_body_string("ok"))
            .mount(&server)
            .await;
        let client = HttpClient::new(config(None)).unwrap();
        let res = client
            .get_feed(&format!("{}/old", server.uri()), false)
            .await
            .unwrap();
        assert_eq!(res.body, b"ok");
        assert_eq!(res.final_url, format!("{}/new", server.uri()));
        assert!(res.redirected);
    }

    #[tokio::test]
    async fn too_many_redirects_is_an_error() {
        let server = MockServer::start().await;
        Mock::given(path("/loop"))
            .respond_with(ResponseTemplate::new(302).insert_header("Location", "/loop"))
            .mount(&server)
            .await;
        let client = HttpClient::new(config(None)).unwrap();
        let err = client
            .get_feed(&format!("{}/loop", server.uri()), false)
            .await
            .unwrap_err();
        assert!(matches!(err, FetchError::TooManyRedirects));
    }

    #[tokio::test]
    async fn slow_server_times_out() {
        let server = MockServer::start().await;
        Mock::given(path("/slow"))
            .respond_with(ResponseTemplate::new(200).set_delay(Duration::from_secs(2)))
            .mount(&server)
            .await;
        let client = HttpClient::new(config(None)).unwrap();
        let err = client
            .get_feed(&format!("{}/slow", server.uri()), false)
            .await
            .unwrap_err();
        assert!(matches!(err, FetchError::Timeout));
    }

    #[tokio::test]
    async fn retries_via_proxy_on_403_and_asks_to_register() {
        let origin = MockServer::start().await;
        Mock::given(path("/feed"))
            .respond_with(ResponseTemplate::new(403))
            .mount(&origin)
            .await;
        let proxy = MockServer::start().await;
        let target = format!("{}/feed", origin.uri());
        Mock::given(method("GET"))
            .and(path("/"))
            .and(header("X-Proxy-Secret", "s"))
            .and(header("X-Target-URL", target.as_str()))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_string("via proxy")
                    .insert_header("X-Original-URL", target.as_str()),
            )
            .mount(&proxy)
            .await;
        let client = HttpClient::new(config(Some(ProxyConfig {
            url: proxy.uri(),
            secret: "s".into(),
        })))
        .unwrap();
        let res = client.get_feed(&target, false).await.unwrap();
        assert_eq!(res.body, b"via proxy");
        assert!(res.via_proxy);
        assert!(res.register_proxy_domain);
        assert!(!res.redirected);
    }

    #[tokio::test]
    async fn non_2xx_is_status_error_without_proxy() {
        let server = MockServer::start().await;
        Mock::given(path("/gone"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;
        let client = HttpClient::new(config(None)).unwrap();
        let err = client
            .get_feed(&format!("{}/gone", server.uri()), false)
            .await
            .unwrap_err();
        assert!(matches!(err, FetchError::Status(404)));
        assert_eq!(err.kind(), "http_status");
    }

    #[tokio::test]
    async fn refuses_private_ip_literal() {
        let server = MockServer::start().await;
        Mock::given(path("/feed"))
            .respond_with(ResponseTemplate::new(200).set_body_string("secret"))
            .expect(0)
            .mount(&server)
            .await;
        let client = HttpClient::new(blocking_config()).unwrap();
        let err = client
            .get_feed(&format!("{}/feed", server.uri()), false)
            .await
            .unwrap_err();
        assert!(matches!(err, FetchError::BlockedAddress(_)), "{err:?}");
        assert_eq!(err.kind(), "blocked_address");
    }

    #[tokio::test]
    async fn refuses_hostnames_resolving_to_private_addresses() {
        let client = HttpClient::new(blocking_config()).unwrap();
        let err = client
            .get_feed("http://localhost:9/feed", false)
            .await
            .unwrap_err();
        assert!(matches!(err, FetchError::BlockedAddress(_)), "{err:?}");
    }

    #[tokio::test]
    async fn refuses_redirect_to_private_ip_literal() {
        let origin = MockServer::start().await;
        let internal = MockServer::start().await;
        Mock::given(path("/secret"))
            .respond_with(ResponseTemplate::new(200).set_body_string("secret"))
            .expect(0)
            .mount(&internal)
            .await;
        Mock::given(path("/feed"))
            .respond_with(
                ResponseTemplate::new(302)
                    .insert_header("Location", format!("{}/secret", internal.uri()).as_str()),
            )
            .mount(&origin)
            .await;
        let mut client = HttpClient::new(blocking_config()).unwrap();
        // 最初の取得先 (テスト用のモックサーバ) だけは例外として通し、リダイレクト先を検査させる
        client.test_allowed_origin = Some(*origin.address());
        let err = client
            .get_feed(&format!("{}/feed", origin.uri()), false)
            .await
            .unwrap_err();
        assert!(matches!(err, FetchError::BlockedAddress(_)), "{err:?}");
    }

    #[test]
    fn classifies_blocked_addresses() {
        let blocked = [
            "127.0.0.1",
            "10.1.2.3",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.0.1",
            "100.127.255.255",
            "0.0.0.0",
            "255.255.255.255",
            "::1",
            "::",
            "fe80::1",
            "fc00::1",
            "fd12:3456::1",
            "::ffff:127.0.0.1",
            "::ffff:10.0.0.1",
            "::ffff:169.254.169.254",
        ];
        for ip in blocked {
            assert!(is_blocked_ip(ip.parse().unwrap()), "{ip} should be blocked");
        }
        let allowed = [
            "8.8.8.8",
            "172.32.0.1",
            "100.128.0.1",
            "93.184.216.34",
            "2001:4860:4860::8888",
            "::ffff:8.8.8.8",
        ];
        for ip in allowed {
            assert!(
                !is_blocked_ip(ip.parse().unwrap()),
                "{ip} should be allowed"
            );
        }
    }

    #[tokio::test]
    async fn sends_cookies_only_to_the_host_that_set_them() {
        let other = MockServer::start().await;
        Mock::given(path("/final"))
            .respond_with(|req: &wiremock::Request| {
                let has_cookie = req.headers.get("cookie").is_some();
                ResponseTemplate::new(200).set_body_string(if has_cookie {
                    "leaked"
                } else {
                    "clean"
                })
            })
            .mount(&other)
            .await;
        let origin = MockServer::start().await;
        // 127.0.0.1 で Cookie を受け取り、同じホストの別パスを経由して localhost (別ホスト) へ
        Mock::given(path("/start"))
            .respond_with(
                ResponseTemplate::new(302)
                    .insert_header("Set-Cookie", "session=abc; Path=/")
                    .insert_header("Location", "/same-host"),
            )
            .mount(&origin)
            .await;
        Mock::given(path("/same-host"))
            .and(header("Cookie", "session=abc"))
            .respond_with(ResponseTemplate::new(302).insert_header(
                "Location",
                format!("http://localhost:{}/final", other.address().port()).as_str(),
            ))
            .mount(&origin)
            .await;
        let client = HttpClient::new(config(None)).unwrap();
        let res = client
            .get_feed(&format!("{}/start", origin.uri()), false)
            .await
            .unwrap();
        assert_eq!(res.body, b"clean");
    }

    #[tokio::test]
    async fn refuses_bodies_over_the_limit() {
        let server = MockServer::start().await;
        Mock::given(path("/big"))
            .respond_with(ResponseTemplate::new(200).set_body_bytes(vec![b'a'; 2048]))
            .mount(&server)
            .await;
        Mock::given(path("/small"))
            .respond_with(ResponseTemplate::new(200).set_body_bytes(vec![b'a'; 1024]))
            .mount(&server)
            .await;
        let client = HttpClient::new(HttpConfig {
            max_body_bytes: 1024,
            ..config(None)
        })
        .unwrap();
        let err = client
            .get_feed(&format!("{}/big", server.uri()), false)
            .await
            .unwrap_err();
        assert!(matches!(err, FetchError::TooLarge(_)), "{err:?}");
        assert_eq!(err.kind(), "too_large");
        let ok = client
            .get_feed(&format!("{}/small", server.uri()), false)
            .await
            .unwrap();
        assert_eq!(ok.body.len(), 1024);
    }
}
