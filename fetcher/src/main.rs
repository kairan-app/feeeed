use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, Subcommand};
use fetcher::http::{DEFAULT_MAX_BODY_BYTES, HttpConfig, ProxyConfig};

#[derive(Parser)]
#[command(name = "fetcher")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// 本番の保存済みデータと突き合わせる (DB には書き込まない)
    Shadow {
        #[arg(long, env = "FETCHER_API_URL")]
        api_url: String,
        #[arg(long, env = "FETCHER_TOKEN", hide_env_values = true)]
        token: String,
        #[arg(long, default_value_t = 50)]
        max: u32,
        #[arg(long, default_value = "random")]
        order: String,
        /// dispatcher に渡すチャンネルの絞り込み。`due` (既定、今取り込むべきものだけ) か
        /// `all` (停止中を除く全チャンネルから検証用にサンプル)
        #[arg(long, default_value = "due")]
        scope: String,
        #[arg(long, env = "FETCHER_CONCURRENCY", default_value_t = 2)]
        concurrency: usize,
        /// レポートの出力先。本番の値を含むのでコミットしないこと (既定の tmp/ は gitignore 下)
        #[arg(long, default_value = "tmp/shadow-report.jsonl")]
        out: PathBuf,
        #[arg(long, env = "FETCHER_USER_AGENT", default_value = "Faraday v2.14.3")]
        user_agent: String,
        #[arg(long, env = "FEED_PROXY_URL")]
        proxy_url: Option<String>,
        #[arg(long, env = "FEED_PROXY_SECRET", hide_env_values = true)]
        proxy_secret: Option<String>,
    },
    /// 本番の常駐モード: Rails から貸し出しを受けて取得し、結果を Rails に送る
    Run {
        #[arg(long, env = "FETCHER_API_URL")]
        api_url: String,
        #[arg(long, env = "FETCHER_TOKEN", hide_env_values = true)]
        token: String,
        #[arg(long, env = "FETCHER_CONCURRENCY", default_value_t = 8)]
        concurrency: usize,
        #[arg(long, env = "FETCHER_USER_AGENT", default_value = "Faraday v2.14.3")]
        user_agent: String,
        #[arg(long, env = "FEED_PROXY_URL")]
        proxy_url: Option<String>,
        #[arg(long, env = "FEED_PROXY_SECRET", hide_env_values = true)]
        proxy_secret: Option<String>,
    },
    /// DIR/*.xml を整形して DIR/*.golden.json と比べる (比較用コーパス向け)
    GoldenCheck { dir: PathBuf },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let builder = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env());
    if matches!(cli.command, Command::Run { .. }) {
        builder.json().init();
    } else {
        builder.init();
    }
    match cli.command {
        Command::Shadow {
            api_url,
            token,
            max,
            order,
            scope,
            concurrency,
            out,
            user_agent,
            proxy_url,
            proxy_secret,
        } => {
            let proxy = proxy_url
                .zip(proxy_secret)
                .map(|(url, secret)| ProxyConfig { url, secret });
            fetcher::shadow::run_shadow(fetcher::shadow::ShadowOptions {
                api_url,
                token,
                max,
                order,
                scope,
                concurrency,
                out,
                http: HttpConfig {
                    user_agent,
                    connect_timeout: Duration::from_secs(10),
                    total_timeout: Duration::from_secs(30),
                    proxy,
                    min_host_interval: Duration::from_secs(1),
                    max_body_bytes: DEFAULT_MAX_BODY_BYTES,
                    // 内部ネットワークへの取得を防ぐ。CLI からは許可しない
                    allow_private_addresses: false,
                },
            })
            .await
        }
        Command::Run {
            api_url,
            token,
            concurrency,
            user_agent,
            proxy_url,
            proxy_secret,
        } => {
            let proxy = proxy_url
                .zip(proxy_secret)
                .map(|(url, secret)| ProxyConfig { url, secret });
            fetcher::run::run(
                fetcher::run::RunOptions {
                    api_url,
                    token,
                    concurrency,
                    idle_wait: Duration::from_secs(60),
                    deadline: Duration::from_secs(5 * 60),
                    result_retry_base: Duration::from_secs(2),
                    http: HttpConfig {
                        user_agent,
                        connect_timeout: Duration::from_secs(10),
                        total_timeout: Duration::from_secs(30),
                        proxy,
                        min_host_interval: Duration::from_secs(1),
                        max_body_bytes: DEFAULT_MAX_BODY_BYTES,
                        // 内部ネットワークへの取得を防ぐ。CLI からは許可しない
                        allow_private_addresses: false,
                    },
                },
                shutdown_signal(),
            )
            .await
        }
        Command::GoldenCheck { dir } => fetcher::golden_check(&dir),
    }
}

/// systemd の stop (SIGTERM) と Ctrl-C を待つ
async fn shutdown_signal() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("failed to install SIGTERM handler");
    tokio::select! {
        _ = term.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
    tracing::info!("shutdown signal received");
}
