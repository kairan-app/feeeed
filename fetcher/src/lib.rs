pub mod encoding;
pub mod filters;
pub mod model;
pub mod ruby;

use model::ShapedFeed;

/// フィードの本文を Rails の取り込みと同じ規則で整形する (HTTP を使わない。OGP は取らない)。
pub fn golden_output(_body: &[u8], _feed_url: &str) -> anyhow::Result<ShapedFeed> {
    unimplemented!("Task 6 で実装する")
}
