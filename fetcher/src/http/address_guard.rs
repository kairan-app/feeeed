//! 内部ネットワークへの取得 (SSRF) を防ぐ。フィードの URL は利用者が登録したものなので、
//! 取得先がループバック・プライベート・リンクローカル (クラウドのメタデータ) などのアドレスなら接続しない。
//! IP リテラルのホストは [`is_blocked_ip`] で各リダイレクトの前に調べ、ホスト名は
//! [`PublicOnlyResolver`] が名前解決の結果から該当アドレスを除く (DNS リバインディングもここで止まる)。
//! IPv6 の中に IPv4 を埋め込む形式 (IPv4 射影・IPv4 互換・NAT64・6to4) は中の IPv4 で判定し、Teredo は塞ぐ。

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

fn embedded_v4(hi: u16, lo: u16) -> Ipv4Addr {
    let [a, b] = hi.to_be_bytes();
    let [c, d] = lo.to_be_bytes();
    Ipv4Addr::new(a, b, c, d)
}

fn is_blocked_v6(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_blocked_v4(v4);
    }
    let seg = ip.segments();
    // IPv4 互換アドレス (::a.b.c.d、非推奨)。:: と ::1 も 0.0.0.0/8 として塞がれる
    if seg[..6] == [0; 6] {
        return is_blocked_v4(embedded_v4(seg[6], seg[7]));
    }
    // NAT64 の well-known prefix (64:ff9b::/96): 末尾 32 ビットの IPv4 で判定する
    if seg[..6] == [0x64, 0xff9b, 0, 0, 0, 0] {
        return is_blocked_v4(embedded_v4(seg[6], seg[7]));
    }
    // ローカル用の NAT64 (64:ff9b:1::/48) は中の宛先の形が決まっていないので塞ぐ
    if seg[..3] == [0x64, 0xff9b, 1] {
        return true;
    }
    // 6to4 (2002::/16): 続く 32 ビットの IPv4 で判定する
    if seg[0] == 0x2002 {
        return is_blocked_v4(embedded_v4(seg[1], seg[2]));
    }
    // Teredo (2001:0::/32): 中の宛先を確かめにくいので塞ぐ
    if seg[0] == 0x2001 && seg[1] == 0 {
        return true;
    }
    let first = seg[0];
    ip.is_multicast() // ff00::/8
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

#[cfg(test)]
mod tests {
    use super::*;

    fn blocked(s: &str) -> bool {
        is_blocked_ip(s.parse().unwrap())
    }

    #[test]
    fn nat64_follows_the_embedded_ipv4() {
        assert!(blocked("64:ff9b::192.168.0.1"));
        assert!(blocked("64:ff9b::7f00:1"));
        assert!(!blocked("64:ff9b::8.8.8.8"));
        // ローカル用の NAT64 は中の宛先が分からないので塞ぐ
        assert!(blocked("64:ff9b:1::8.8.8.8"));
    }

    #[test]
    fn six_to_four_follows_the_embedded_ipv4() {
        assert!(blocked("2002:c0a8:0001::1")); // 192.168.0.1
        assert!(blocked("2002:7f00:0001::1")); // 127.0.0.1
        assert!(!blocked("2002:0808:0808::1")); // 8.8.8.8
    }

    #[test]
    fn teredo_is_blocked() {
        assert!(blocked("2001:0:4136:e378:8000:63bf:3fff:fdd2"));
        assert!(!blocked("2001:4860:4860::8888"));
    }

    #[test]
    fn ipv4_compatible_follows_the_embedded_ipv4() {
        assert!(blocked("::192.168.0.1"));
        assert!(blocked("::1"));
        assert!(blocked("::"));
        assert!(!blocked("::8.8.8.8"));
    }

    #[test]
    fn existing_ranges_are_still_blocked() {
        assert!(blocked("::ffff:10.0.0.1"));
        assert!(blocked("fe80::1"));
        assert!(blocked("fd00::1"));
        assert!(blocked("169.254.169.254"));
        assert!(!blocked("2606:4700::1111"));
        assert!(!blocked("1.1.1.1"));
    }
}
