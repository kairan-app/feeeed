//! 内部ネットワークへの取得 (SSRF) を防ぐ。フィードの URL は利用者が登録したものなので、
//! 取得先がループバック・プライベート・リンクローカル (クラウドのメタデータ) などのアドレスなら接続しない。
//! IP リテラルのホストは [`is_blocked_ip`] で各リダイレクトの前に調べ、ホスト名は
//! [`PublicOnlyResolver`] が名前解決の結果から該当アドレスを除く (DNS リバインディングもここで止まる)。

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use reqwest::dns::{Addrs, Name, Resolve, Resolving};

/// 名前解決の結果がすべて取得してはいけないアドレスだったときのエラー。
/// reqwest のエラーの source をたどってこの型が見つかれば `FetchError::BlockedAddress` にする。
#[derive(Debug, thiserror::Error)]
#[error("{host} resolves only to non-public addresses")]
pub struct BlockedAddressError {
    pub host: String,
}

pub fn is_blocked_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_blocked_v4(v4),
        IpAddr::V6(v6) => is_blocked_v6(v6),
    }
}

fn is_blocked_v4(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    ip.is_loopback() // 127.0.0.0/8
        || ip.is_private() // 10/8, 172.16/12, 192.168/16
        || ip.is_link_local() // 169.254/16
        || ip.is_broadcast() // 255.255.255.255
        || ip.is_multicast() // 224/4
        || a == 0 // 0.0.0.0/8 (unspecified を含む)
        || (a == 100 && (64..128).contains(&b)) // 100.64/10 (CGNAT)
        || a >= 240 // 240/4 (予約)
}

fn is_blocked_v6(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_blocked_v4(v4);
    }
    let first = ip.segments()[0];
    ip.is_loopback() // ::1
        || ip.is_unspecified() // ::
        || ip.is_multicast() // ff00::/8
        || (first & 0xffc0) == 0xfe80 // fe80::/10 (リンクローカル)
        || (first & 0xfe00) == 0xfc00 // fc00::/7 (ULA)
}

/// システムの名前解決を使い、取得してはいけないアドレスを取り除く reqwest 用のリゾルバ。
/// 残るアドレスが無ければ [`BlockedAddressError`] で失敗させる。
pub struct PublicOnlyResolver;

impl Resolve for PublicOnlyResolver {
    fn resolve(&self, name: Name) -> Resolving {
        Box::pin(async move {
            let host = name.as_str().to_string();
            let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), 0))
                .await?
                .filter(|addr| !is_blocked_ip(addr.ip()))
                .collect();
            if addrs.is_empty() {
                return Err(Box::new(BlockedAddressError { host }) as _);
            }
            Ok(Box::new(addrs.into_iter()) as Addrs)
        })
    }
}
