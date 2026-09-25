pub mod host_gate;

use std::time::Duration;

use reqwest::header::{COOKIE, LOCATION, SET_COOKIE};
use reqwest::redirect::Policy;

use host_gate::HostGate;

/// Faraday の follow_redirects の既定と同じ (3回まで追い、4回目で失敗)。
const MAX_REDIRECTS: usize = 3;

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
            FetchError::Other(_) => "other",
        }
    }

    fn from_reqwest(e: reqwest::Error) -> Self {
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
}

impl HttpClient {
    pub fn new(config: HttpConfig) -> anyhow::Result<Self> {
        let client = reqwest::Client::builder()
            .user_agent(config.user_agent.clone())
            .connect_timeout(config.connect_timeout)
            .timeout(config.total_timeout)
            .redirect(Policy::none())
            .build()?;
        let gate = HostGate::new(config.min_host_interval);
        Ok(Self {
            client,
            config,
            gate,
        })
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
    /// 引き継ぐ (Faraday で毎回新しい cookie_jar を作っているのと同じ)。ホストごとの
    /// 門番は各リダイレクト先のホストにも適用する。
    async fn direct(&self, url: &str) -> Result<FetchResponse, FetchError> {
        let mut current = url::Url::parse(url).map_err(|e| FetchError::Other(e.to_string()))?;
        let mut cookies: Vec<String> = Vec::new();
        for hops in 0..=MAX_REDIRECTS {
            let host = current.host_str().unwrap_or_default().to_string();
            let _permit = self.gate.acquire(&host).await;
            let mut req = self.client.get(current.clone());
            if !cookies.is_empty() {
                req = req.header(COOKIE, cookies.join("; "));
            }
            let res = req.send().await.map_err(FetchError::from_reqwest)?;
            for value in res.headers().get_all(SET_COOKIE) {
                if let Some(pair) = value.to_str().ok().and_then(|v| v.split(';').next()) {
                    cookies.push(pair.trim().to_string());
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
            let body = res
                .bytes()
                .await
                .map_err(FetchError::from_reqwest)?
                .to_vec();
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
        let body = res
            .bytes()
            .await
            .map_err(FetchError::from_reqwest)?
            .to_vec();
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
}
