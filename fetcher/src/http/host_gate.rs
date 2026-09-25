use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};
use tokio::time::Instant;

/// 同じホストへの同時アクセスを1本に絞り、前回の解放から `min_interval` 経つまで
/// 次のアクセスを待たせる門番 (フィード取得と OGP 取得の両方で共有する)。
pub struct HostGate {
    hosts: Mutex<HashMap<String, Arc<AsyncMutex<Option<Instant>>>>>,
    min_interval: Duration,
}

/// `acquire` が返す許可証。drop されるとそのホストの次のアクセスを許可する
/// (このとき「前回アクセス時刻」を更新する)。
pub struct HostPermit {
    guard: OwnedMutexGuard<Option<Instant>>,
}

impl Drop for HostPermit {
    fn drop(&mut self) {
        *self.guard = Some(Instant::now());
    }
}

impl HostGate {
    pub fn new(min_interval: Duration) -> Self {
        Self {
            hosts: Mutex::new(HashMap::new()),
            min_interval,
        }
    }

    pub async fn acquire(&self, host: &str) -> HostPermit {
        let slot = {
            let mut hosts = self.hosts.lock().unwrap();
            hosts.entry(host.to_ascii_lowercase()).or_default().clone()
        };
        let guard = slot.lock_owned().await;
        if let Some(last) = *guard {
            let ready_at = last + self.min_interval;
            if ready_at > Instant::now() {
                tokio::time::sleep_until(ready_at).await;
            }
        }
        HostPermit { guard }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::time::Instant;

    #[tokio::test]
    async fn same_host_is_serialized_with_interval() {
        let gate = Arc::new(HostGate::new(Duration::from_millis(200)));
        let active = Arc::new(AtomicUsize::new(0));
        let start = Instant::now();
        let mut handles = Vec::new();
        for _ in 0..3 {
            let gate = gate.clone();
            let active = active.clone();
            handles.push(tokio::spawn(async move {
                let _permit = gate.acquire("example.com").await;
                assert_eq!(
                    active.fetch_add(1, Ordering::SeqCst),
                    0,
                    "同じホストに同時アクセスしている"
                );
                tokio::time::sleep(Duration::from_millis(10)).await;
                active.fetch_sub(1, Ordering::SeqCst);
            }));
        }
        for h in handles {
            h.await.unwrap();
        }
        assert!(start.elapsed() >= Duration::from_millis(400));
    }

    #[tokio::test]
    async fn different_hosts_do_not_wait() {
        let gate = HostGate::new(Duration::from_secs(5));
        let start = Instant::now();
        let _a = gate.acquire("a.example").await;
        let _b = gate.acquire("b.example").await;
        assert!(start.elapsed() < Duration::from_millis(100));
    }
}
