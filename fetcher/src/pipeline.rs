//! 貸し出された1チャンネルの処理: 取得 → フィルタ → パース → 整形 → 新しい entry の照会 → OGP → result。
//! Rails の ChannelItemsUpdaterJob (update_info + fetch_and_save_items) と同じ結果になるように作る

use std::collections::HashSet;

use crate::api_client::{ApiClient, Lease};
use crate::dispatcher_client::NewGuidQuery;
use crate::http::HttpClient;
use crate::ogp::fetch_ogp;
use crate::result::{
    ResultPayload, data_extra_by_guid, latest_guids, result_channel, result_entry,
};
use crate::shape;
use crate::shape::entry::ImageCandidate;

/// guid_lookups に1回で送る entry の数
const LOOKUP_CHUNK: usize = 1000;

/// `Err` は「結果を送らずに lease の期限切れに任せる」(guid の照会ができず、新しい entry を決められない)
pub async fn process_lease(
    lease: &Lease,
    http: &HttpClient,
    api: &ApiClient,
    proxy_domains: &HashSet<String>,
) -> anyhow::Result<ResultPayload> {
    let res = match http.get_feed(&lease.feed_url, lease.use_proxy).await {
        Ok(r) => r,
        Err(e) => return Ok(ResultPayload::failed(e.kind(), e.to_string())),
    };
    // Rails は response.env.url をそのまま使う。リダイレクトしていなければ lease の feed_url と同じで、
    // res.final_url は url::Url で正規化されてしまうので使い分ける
    let base_url = if res.redirected {
        res.final_url.as_str()
    } else {
        lease.feed_url.as_str()
    };
    let register_proxy_urls = if res.register_proxy_domain {
        vec![lease.feed_url.clone()]
    } else {
        vec![]
    };
    let prepared = match crate::prepare(&res.body, base_url) {
        Ok(p) => p,
        Err(e) => return Ok(ResultPayload::failed("parse", e.to_string())),
    };

    // チャンネル情報 (Channel.save_from は final_feed_url を使う)
    let ogp = match shape::channel::ogp_target(&prepared.feed, base_url) {
        Some(target) => fetch_ogp(http, &target, proxy_domains).await,
        None => None,
    };
    let meta = shape::channel::channel_meta(&prepared.feed, base_url, ogp.as_ref());
    let site_url = meta
        .as_ref()
        .and_then(|m| m.site_url.clone())
        .or_else(|| lease.site_url.clone());

    // 新しい entry だけを残す
    let (drafts, _skipped) = shape::entry::draft_entries(&prepared.feed, site_url.as_deref());
    let queries: Vec<NewGuidQuery> = drafts
        .iter()
        .map(|d| NewGuidQuery {
            entry_id: d.raw_entry_id.clone(),
            url: d.raw_url.clone(),
        })
        .collect();
    let mut flags = Vec::with_capacity(queries.len());
    for chunk in queries.chunks(LOOKUP_CHUNK) {
        flags.extend(api.new_flags(lease.channel_id, chunk).await?);
    }
    let new_drafts: Vec<_> = drafts
        .into_iter()
        .zip(flags)
        .filter_map(|(d, is_new)| is_new.then_some(d))
        .collect();
    let extras = data_extra_by_guid(&new_drafts);

    // 画像が無い新しい entry は、記事の OGP 画像を取る (Rails と同じ)
    let mut resolved = Vec::with_capacity(new_drafts.len());
    for d in new_drafts {
        let ogp_image = if d.image == ImageCandidate::NeedsOgp {
            fetch_ogp(http, &d.url, proxy_domains)
                .await
                .and_then(|o| o.image)
        } else {
            None
        };
        resolved.push((d, ogp_image, false));
    }
    let (entries, _) = shape::entry::finalize_entries(resolved);

    Ok(ResultPayload {
        fetched: true,
        error: None,
        final_url: res.redirected.then(|| res.final_url.clone()),
        register_proxy_urls,
        channel: meta.map(|m| result_channel(m, prepared.applied_filters, prepared.filter_details)),
        entries: entries
            .into_iter()
            .map(|e| {
                let extra = extras.get(&e.guid);
                result_entry(e, extra)
            })
            .collect(),
        latest_guids: latest_guids(&prepared.feed),
    })
}
