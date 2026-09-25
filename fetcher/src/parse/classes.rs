//! Feedjira 4.0.2 の各クラスの `element` / `elements` 宣言を、宣言順のまま写したもの。
//! 使わない値のルールも、文脈の切り替えと「最初の1回」の判定に効くものは残す。
//! `include` で共有している宣言はマクロにまとめ、追加のルールを引数で受け取って1つの配列にする。
//!
//! `bundle show feedjira` の `lib/feedjira/parser/*.rb` と `lib/feedjira/*_utilities.rb`
//! (`atom_entry_utilities.rb` / `rss_entry_utilities.rb`) を実際に読んで確認した内容。
//! 当初の推定 (このファイルの元になった brief) から次の3箇所を実際の Ruby の宣言に合わせて修正した:
//!
//! - `GOOGLE_ALERTS` (フィード側): `AtomGoogleAlerts` は `Atom` を継承せず独自に
//!   `element :link, as: :feed_url, value: :href, with: { rel: "self" }` と
//!   `element :link, as: :url, value: :href, with: { rel: "self" }` を宣言している
//!   (`url` の条件は `type: "text/html"` ではなく `rel: "self"`)。`icon` も無い。
//!   `def url` のオーバーライドも無いので、`url` は `@url` の値そのもの
//!   (`Atom` の `@url || (links - [feed_url]).last` のような links へのフォールバックは無い)。
//! - `RSS_FEEDBURNER` (フィード側): `RSSFeedBurner` は `RSS` を継承せず、
//!   `title` / `description` / `link → url` / `lastBuildDate → last_built` / `item → entries` だけを持つ。
//!   `image` / `language` / `ttl` / `a10:link → url` は無い。
//! - `ATOM_FEEDBURNER` (フィード側): `AtomFeedBurner` は `Atom` を継承せず、
//!   `link[type="text/html"] → url_text_html` と `link[type 無し] → url_notype` を持つ
//!   (`def url` は `@url || @url_text_html || @url_notype` で、`@url` は `attr_writer` のみで SAX からは設定されない)。
//!   `elements :link, as: :links` も `icon` も無いので、`links` によるフォールバックも存在しない。
//!
//! (`ATOM_FEEDBURNER_ENTRY` / `RSS_FEEDBURNER_ENTRY` / `GOOGLE_ALERTS_ENTRY` / `YOUTUBE` / `YOUTUBE_ENTRY` /
//! `ITUNES` / `ITUNES_ITEM` / `RSS` / `RSS_ENTRY` / `ATOM` / `ATOM_ENTRY` は実際の宣言と一致することを確認済み)

use super::sax::{Class, Cond::*, Rule::*, Setter::*};

const NO_ATTRS: &[(&str, &str)] = &[];

/// RSSImage / ITunesRSSOwner / ITunesRSSCategory / PodloveChapter の代わり。中の要素を吸収するだけ
pub static ABSORB: Class = Class {
    rules: &[],
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static GUID: Class = Class {
    rules: &[],
    value_field: Some("guid"),
    attr_fields: &[("isPermaLink", "is_perma_link")],
};

/// RSSEntryUtilities の宣言 (enclosure → image を除く) + 追加のルール
macro_rules! rss_entry_rules {
    ($($extra:expr),* $(,)?) => {
        &[
            Text { name: "title", with: &[], field: "title", setter: Plain },
            Text { name: "content:encoded", with: &[], field: "content", setter: Plain },
            Text { name: "a10:content", with: &[], field: "content", setter: Plain },
            Text { name: "description", with: &[], field: "summary", setter: Plain },
            Text { name: "link", with: &[], field: "url", setter: Plain },
            Attr { name: "a10:link", with: &[], attr: "href", field: "url", setter: Plain },
            Text { name: "author", with: &[], field: "author", setter: Plain },
            Text { name: "dc:creator", with: &[], field: "author", setter: Plain },
            Text { name: "a10:name", with: &[], field: "author", setter: Plain },
            Text { name: "pubDate", with: &[], field: "published", setter: KeepOldest },
            Text { name: "pubdate", with: &[], field: "published", setter: KeepOldest },
            Text { name: "issued", with: &[], field: "published", setter: KeepOldest },
            Text { name: "dc:date", with: &[], field: "published", setter: KeepOldest },
            Text { name: "dc:Date", with: &[], field: "published", setter: KeepOldest },
            Text { name: "dcterms:created", with: &[], field: "published", setter: KeepOldest },
            Text { name: "dcterms:modified", with: &[], field: "updated", setter: KeepNewest },
            Text { name: "a10:updated", with: &[], field: "updated", setter: KeepNewest },
            Child { name: "guid", with: &[], class: &GUID, field: "entry_id" },
            Text { name: "dc:identifier", with: &[], field: "dc_identifier", setter: Plain },
            Attr { name: "media:thumbnail", with: &[], attr: "url", field: "image", setter: Plain },
            Attr { name: "media:content", with: &[], attr: "url", field: "image", setter: Plain },
            Text { name: "comments", with: &[], field: "comments", setter: Plain },
            $($extra),*
        ]
    };
}

/// AtomEntryUtilities の宣言 (link を除く) + 追加のルール
macro_rules! atom_entry_rules {
    ($($extra:expr),* $(,)?) => {
        &[
            Text { name: "title", with: &[Eq("type", "html")], field: "raw_title", setter: Plain },
            Text { name: "title", with: &[Eq("type", "xhtml")], field: "raw_title", setter: Plain },
            Text { name: "title", with: &[Eq("type", "xml")], field: "raw_title", setter: Plain },
            Text { name: "title", with: &[Eq("type", "text")], field: "title", setter: Plain },
            Text { name: "title", with: &[Absent("type")], field: "title", setter: Plain },
            Attr { name: "title", with: &[], attr: "type", field: "title_type", setter: Plain },
            Text { name: "name", with: &[], field: "author", setter: Plain },
            Text { name: "content", with: &[], field: "content", setter: Plain },
            Text { name: "summary", with: &[], field: "summary", setter: Plain },
            Attr { name: "enclosure", with: &[], attr: "href", field: "image", setter: Plain },
            Text { name: "published", with: &[], field: "published", setter: KeepOldest },
            Text { name: "id", with: &[], field: "entry_id", setter: Plain },
            Text { name: "created", with: &[], field: "published", setter: KeepOldest },
            Text { name: "issued", with: &[], field: "published", setter: KeepOldest },
            Text { name: "updated", with: &[], field: "updated", setter: KeepNewest },
            Text { name: "modified", with: &[], field: "updated", setter: KeepNewest },
            $($extra),*
        ]
    };
}

/// RSS のフィード側の宣言
macro_rules! rss_feed_rules {
    ($entry:expr) => {
        &[
            Text {
                name: "description",
                with: &[],
                field: "description",
                setter: Plain,
            },
            Child {
                name: "image",
                with: &[],
                class: &ABSORB,
                field: "image",
            },
            Text {
                name: "language",
                with: &[],
                field: "language",
                setter: Plain,
            },
            Text {
                name: "lastBuildDate",
                with: &[],
                field: "last_built",
                setter: Plain,
            },
            Text {
                name: "link",
                with: &[],
                field: "url",
                setter: Plain,
            },
            Attr {
                name: "a10:link",
                with: &[],
                attr: "href",
                field: "url",
                setter: Plain,
            },
            Text {
                name: "title",
                with: &[],
                field: "title",
                setter: Plain,
            },
            Text {
                name: "ttl",
                with: &[],
                field: "ttl",
                setter: Plain,
            },
            Collection {
                name: "item",
                class: $entry,
                field: "entries",
            },
        ]
    };
}

/// Atom のフィード側の宣言 (AtomGoogleAlerts / AtomFeedBurner はこれを共有していないので個別に定義する)
macro_rules! atom_feed_rules {
    ($entry:expr) => {
        &[
            Text {
                name: "title",
                with: &[],
                field: "title",
                setter: Plain,
            },
            Text {
                name: "subtitle",
                with: &[],
                field: "description",
                setter: Plain,
            },
            Attr {
                name: "link",
                with: &[Eq("type", "text/html")],
                attr: "href",
                field: "url",
                setter: Plain,
            },
            Attr {
                name: "link",
                with: &[Eq("rel", "self")],
                attr: "href",
                field: "feed_url",
                setter: Plain,
            },
            Attr {
                name: "link",
                with: &[],
                attr: "href",
                field: "links",
                setter: Append,
            },
            Collection {
                name: "entry",
                class: $entry,
                field: "entries",
            },
            Text {
                name: "icon",
                with: &[],
                field: "icon",
                setter: Plain,
            },
        ]
    };
}

// ---- RSS ----

pub static RSS_ENTRY: Class = Class {
    rules: rss_entry_rules!(Attr {
        name: "enclosure",
        with: &[],
        attr: "url",
        field: "image",
        setter: Plain
    }),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static RSS: Class = Class {
    rules: rss_feed_rules!(&RSS_ENTRY),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static RSS_FEEDBURNER_ENTRY: Class = Class {
    rules: rss_entry_rules!(
        Attr {
            name: "enclosure",
            with: &[],
            attr: "url",
            field: "image",
            setter: Plain
        },
        Text {
            name: "feedburner:origLink",
            with: &[],
            field: "orig_link",
            setter: Plain
        },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

/// RSSFeedBurner (rss_feed_burner.rb) は RSS を継承しない独自の宣言:
/// title / description / link→url / lastBuildDate→last_built / item→entries だけ
/// (image / language / ttl / a10:link→url は無い)。
pub static RSS_FEEDBURNER: Class = Class {
    rules: &[
        Text {
            name: "title",
            with: &[],
            field: "title",
            setter: Plain,
        },
        Text {
            name: "description",
            with: &[],
            field: "description",
            setter: Plain,
        },
        Text {
            name: "link",
            with: &[],
            field: "url",
            setter: Plain,
        },
        Text {
            name: "lastBuildDate",
            with: &[],
            field: "last_built",
            setter: Plain,
        },
        Collection {
            name: "item",
            class: &RSS_FEEDBURNER_ENTRY,
            field: "entries",
        },
    ],
    value_field: None,
    attr_fields: NO_ATTRS,
};

// ---- iTunes ----

pub static ITUNES_ITEM: Class = Class {
    rules: rss_entry_rules!(
        Text {
            name: "itunes:author",
            with: &[],
            field: "itunes_author",
            setter: Plain
        },
        Text {
            name: "itunes:block",
            with: &[],
            field: "itunes_block",
            setter: Plain
        },
        Text {
            name: "itunes:duration",
            with: &[],
            field: "itunes_duration",
            setter: Plain
        },
        Text {
            name: "itunes:explicit",
            with: &[],
            field: "itunes_explicit",
            setter: Plain
        },
        Text {
            name: "itunes:keywords",
            with: &[],
            field: "itunes_keywords",
            setter: Plain
        },
        Text {
            name: "itunes:subtitle",
            with: &[],
            field: "itunes_subtitle",
            setter: Plain
        },
        Attr {
            name: "itunes:image",
            with: &[],
            attr: "href",
            field: "itunes_image",
            setter: Plain
        },
        Text {
            name: "itunes:isClosedCaptioned",
            with: &[],
            field: "itunes_closed_captioned",
            setter: Plain
        },
        Text {
            name: "itunes:order",
            with: &[],
            field: "itunes_order",
            setter: Plain
        },
        Text {
            name: "itunes:season",
            with: &[],
            field: "itunes_season",
            setter: Plain
        },
        Text {
            name: "itunes:episode",
            with: &[],
            field: "itunes_episode",
            setter: Plain
        },
        Text {
            name: "itunes:title",
            with: &[],
            field: "itunes_title",
            setter: Plain
        },
        Text {
            name: "itunes:episodeType",
            with: &[],
            field: "itunes_episode_type",
            setter: Plain
        },
        Text {
            name: "itunes:summary",
            with: &[],
            field: "itunes_summary",
            setter: Plain
        },
        Attr {
            name: "enclosure",
            with: &[],
            attr: "length",
            field: "enclosure_length",
            setter: Plain
        },
        Attr {
            name: "enclosure",
            with: &[],
            attr: "type",
            field: "enclosure_type",
            setter: Plain
        },
        Attr {
            name: "enclosure",
            with: &[],
            attr: "url",
            field: "enclosure_url",
            setter: Plain
        },
        Collection {
            name: "psc:chapter",
            class: &ABSORB,
            field: "raw_chapters"
        },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static ITUNES: Class = Class {
    rules: &[
        Text {
            name: "copyright",
            with: &[],
            field: "copyright",
            setter: Plain,
        },
        Text {
            name: "description",
            with: &[],
            field: "description",
            setter: Plain,
        },
        Child {
            name: "image",
            with: &[],
            class: &ABSORB,
            field: "image",
        },
        Text {
            name: "language",
            with: &[],
            field: "language",
            setter: Plain,
        },
        Text {
            name: "lastBuildDate",
            with: &[],
            field: "last_built",
            setter: Plain,
        },
        Text {
            name: "link",
            with: &[],
            field: "url",
            setter: Plain,
        },
        Text {
            name: "managingEditor",
            with: &[],
            field: "managing_editor",
            setter: Plain,
        },
        Text {
            name: "title",
            with: &[],
            field: "title",
            setter: Plain,
        },
        Text {
            name: "ttl",
            with: &[],
            field: "ttl",
            setter: Plain,
        },
        Text {
            name: "itunes:author",
            with: &[],
            field: "itunes_author",
            setter: Plain,
        },
        Text {
            name: "itunes:block",
            with: &[],
            field: "itunes_block",
            setter: Plain,
        },
        Attr {
            name: "itunes:image",
            with: &[],
            attr: "href",
            field: "itunes_image",
            setter: Plain,
        },
        Text {
            name: "itunes:explicit",
            with: &[],
            field: "itunes_explicit",
            setter: Plain,
        },
        Text {
            name: "itunes:complete",
            with: &[],
            field: "itunes_complete",
            setter: Plain,
        },
        Text {
            name: "itunes:keywords",
            with: &[],
            field: "itunes_keywords",
            setter: Plain,
        },
        Text {
            name: "itunes:type",
            with: &[],
            field: "itunes_type",
            setter: Plain,
        },
        Text {
            name: "itunes:new_feed_url",
            with: &[],
            field: "itunes_new_feed_url",
            setter: Plain,
        },
        Text {
            name: "itunes:subtitle",
            with: &[],
            field: "itunes_subtitle",
            setter: Plain,
        },
        Text {
            name: "itunes:summary",
            with: &[],
            field: "itunes_summary",
            setter: Plain,
        },
        Collection {
            name: "itunes:category",
            class: &ABSORB,
            field: "itunes_categories",
        },
        Collection {
            name: "itunes:owner",
            class: &ABSORB,
            field: "itunes_owners",
        },
        Collection {
            name: "item",
            class: &ITUNES_ITEM,
            field: "entries",
        },
    ],
    value_field: None,
    attr_fields: NO_ATTRS,
};

// ---- Atom ----

pub static ATOM_ENTRY: Class = Class {
    rules: atom_entry_rules!(
        Attr {
            name: "link",
            with: &[Eq("type", "text/html"), Eq("rel", "alternate")],
            attr: "href",
            field: "url",
            setter: Plain
        },
        Attr {
            name: "link",
            with: &[],
            attr: "href",
            field: "links",
            setter: Append
        },
        Attr {
            name: "media:thumbnail",
            with: &[],
            attr: "url",
            field: "image",
            setter: Plain
        },
        Attr {
            name: "media:content",
            with: &[],
            attr: "url",
            field: "image",
            setter: Plain
        },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static ATOM: Class = Class {
    rules: atom_feed_rules!(&ATOM_ENTRY),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static GOOGLE_ALERTS_ENTRY: Class = Class {
    rules: atom_entry_rules!(
        Attr {
            name: "link",
            with: &[Eq("type", "text/html"), Eq("rel", "alternate")],
            attr: "href",
            field: "url",
            setter: Plain
        },
        Attr {
            name: "link",
            with: &[],
            attr: "href",
            field: "links",
            setter: Append
        },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

/// AtomGoogleAlerts (atom_google_alerts.rb) は Atom を継承しない独自の宣言:
/// `url` / `feed_url` はどちらも `link[rel="self"]` から取る (`url` の条件は `type: "text/html"` ではない)。
/// `icon` も無く、`def url` のオーバーライドも無いので `links` へのフォールバックも無い。
pub static GOOGLE_ALERTS: Class = Class {
    rules: &[
        Text {
            name: "title",
            with: &[],
            field: "title",
            setter: Plain,
        },
        Text {
            name: "subtitle",
            with: &[],
            field: "description",
            setter: Plain,
        },
        Attr {
            name: "link",
            with: &[Eq("rel", "self")],
            attr: "href",
            field: "feed_url",
            setter: Plain,
        },
        Attr {
            name: "link",
            with: &[Eq("rel", "self")],
            attr: "href",
            field: "url",
            setter: Plain,
        },
        Attr {
            name: "link",
            with: &[],
            attr: "href",
            field: "links",
            setter: Append,
        },
        Collection {
            name: "entry",
            class: &GOOGLE_ALERTS_ENTRY,
            field: "entries",
        },
    ],
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static ATOM_FEEDBURNER_ENTRY: Class = Class {
    rules: atom_entry_rules!(
        Attr {
            name: "link",
            with: &[Eq("type", "text/html"), Eq("rel", "alternate")],
            attr: "href",
            field: "url",
            setter: Plain
        },
        Attr {
            name: "link",
            with: &[],
            attr: "href",
            field: "links",
            setter: Append
        },
        Attr {
            name: "media:thumbnail",
            with: &[],
            attr: "url",
            field: "image",
            setter: Plain
        },
        Attr {
            name: "media:content",
            with: &[],
            attr: "url",
            field: "image",
            setter: Plain
        },
        Text {
            name: "feedburner:origLink",
            with: &[],
            field: "orig_link",
            setter: Plain
        },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

/// AtomFeedBurner (atom_feed_burner.rb) は Atom を継承しない独自の宣言:
/// `url` は `link[type="text/html"]` (url_text_html) が無ければ `link[type 無し]` (url_notype)。
/// `elements :link, as: :links` は無いので `links` によるフォールバックも `icon` も無い。
pub static ATOM_FEEDBURNER: Class = Class {
    rules: &[
        Text {
            name: "title",
            with: &[],
            field: "title",
            setter: Plain,
        },
        Text {
            name: "subtitle",
            with: &[],
            field: "description",
            setter: Plain,
        },
        Attr {
            name: "link",
            with: &[Eq("type", "text/html")],
            attr: "href",
            field: "url_text_html",
            setter: Plain,
        },
        Attr {
            name: "link",
            with: &[Absent("type")],
            attr: "href",
            field: "url_notype",
            setter: Plain,
        },
        Collection {
            name: "entry",
            class: &ATOM_FEEDBURNER_ENTRY,
            field: "entries",
        },
    ],
    value_field: None,
    attr_fields: NO_ATTRS,
};

// ---- YouTube ----

pub static YOUTUBE_ENTRY: Class = Class {
    // AtomYoutubeEntry は AtomEntryUtilities の link の宣言を消して、rel=alternate の link だけを持つ
    rules: atom_entry_rules!(
        Attr {
            name: "link",
            with: &[Eq("rel", "alternate")],
            attr: "href",
            field: "url",
            setter: Plain
        },
        Text {
            name: "media:description",
            with: &[],
            field: "content",
            setter: Plain
        },
        Text {
            name: "yt:videoId",
            with: &[],
            field: "youtube_video_id",
            setter: Plain
        },
        Text {
            name: "yt:channelId",
            with: &[],
            field: "youtube_channel_id",
            setter: Plain
        },
        Text {
            name: "media:title",
            with: &[],
            field: "media_title",
            setter: Plain
        },
        Attr {
            name: "media:content",
            with: &[],
            attr: "url",
            field: "media_url",
            setter: Plain
        },
        Attr {
            name: "media:thumbnail",
            with: &[],
            attr: "url",
            field: "media_thumbnail_url",
            setter: Plain
        },
    ),
    value_field: None,
    attr_fields: NO_ATTRS,
};

pub static YOUTUBE: Class = Class {
    rules: &[
        Text {
            name: "title",
            with: &[],
            field: "title",
            setter: Plain,
        },
        Attr {
            name: "link",
            with: &[Eq("rel", "alternate")],
            attr: "href",
            field: "url",
            setter: Plain,
        },
        Attr {
            name: "link",
            with: &[Eq("rel", "self")],
            attr: "href",
            field: "feed_url",
            setter: Plain,
        },
        Text {
            name: "name",
            with: &[],
            field: "author",
            setter: Plain,
        },
        Text {
            name: "yt:channelId",
            with: &[],
            field: "youtube_channel_id",
            setter: Plain,
        },
        Collection {
            name: "entry",
            class: &YOUTUBE_ENTRY,
            field: "entries",
        },
    ],
    value_field: None,
    attr_fields: NO_ATTRS,
};
