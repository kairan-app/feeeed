//! sax-machine 1.3.2 の値の集め方を再現する小さなエンジン。

use std::collections::{HashMap, HashSet};

use quick_xml::Reader;
use quick_xml::events::{BytesRef, BytesStart, Event};

use super::date::parse_datetime;

#[derive(Debug, Clone, Copy)]
pub enum Cond {
    Eq(&'static str, &'static str),
    Absent(&'static str),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Setter {
    Plain,
    KeepOldest,
    KeepNewest,
    Append,
}

#[derive(Debug)]
pub enum Rule {
    Text {
        name: &'static str,
        with: &'static [Cond],
        field: &'static str,
        setter: Setter,
    },
    Attr {
        name: &'static str,
        with: &'static [Cond],
        attr: &'static str,
        field: &'static str,
        setter: Setter,
    },
    Child {
        name: &'static str,
        with: &'static [Cond],
        class: &'static Class,
        field: &'static str,
    },
    Collection {
        name: &'static str,
        class: &'static Class,
        field: &'static str,
    },
}

#[derive(Debug)]
pub struct Class {
    pub rules: &'static [Rule],
    pub value_field: Option<&'static str>,
    pub attr_fields: &'static [(&'static str, &'static str)],
}

#[derive(Debug, Default, Clone)]
pub struct Obj {
    pub fields: HashMap<&'static str, Vec<String>>,
    pub children: HashMap<&'static str, Vec<Obj>>,
}

impl Obj {
    /// 最後の値
    pub fn get(&self, field: &str) -> Option<&str> {
        self.fields
            .get(field)
            .and_then(|v| v.last())
            .map(String::as_str)
    }

    /// Append の値
    pub fn all(&self, field: &str) -> &[String] {
        self.fields.get(field).map(Vec::as_slice).unwrap_or(&[])
    }

    pub fn child(&self, field: &str) -> Option<&Obj> {
        self.children.get(field).and_then(|v| v.last())
    }

    pub fn list(&self, field: &str) -> &[Obj] {
        self.children.get(field).map(Vec::as_slice).unwrap_or(&[])
    }

    fn set(&mut self, field: &'static str, value: String, setter: Setter) {
        match setter {
            Setter::Plain => {
                self.fields.insert(field, vec![value]);
            }
            Setter::Append => self.fields.entry(field).or_default().push(value),
            Setter::KeepOldest | Setter::KeepNewest => {
                let Some(parsed) = parse_datetime(&value) else {
                    return;
                };
                let current = self.get(field).and_then(parse_datetime);
                let replace = match current {
                    None => true,
                    Some(c) if setter == Setter::KeepOldest => parsed < c,
                    Some(c) => parsed > c,
                };
                if replace {
                    self.fields.insert(field, vec![parsed.to_rfc3339()]);
                }
            }
        }
    }
}

enum FrameKind {
    Root,
    /// Text ルール。値はいまのオブジェクトに入れる
    Text(usize),
    /// Child か Collection。新しいオブジェクト
    Object {
        rule: usize,
    },
}

struct Frame {
    kind: FrameKind,
    name: String,
    buffer: Option<String>,
    /// Object / Root のときだけ使う
    obj: Obj,
    class: &'static Class,
    parsed: HashSet<usize>,
}

impl Frame {
    fn object(kind: FrameKind, name: String, class: &'static Class, obj: Obj) -> Self {
        Frame {
            kind,
            name,
            buffer: None,
            obj,
            class,
            parsed: HashSet::new(),
        }
    }
}

fn conds_match(conds: &[Cond], attrs: &HashMap<String, String>) -> bool {
    conds.iter().all(|c| match c {
        Cond::Eq(k, v) => attrs.get(*k).map(String::as_str) == Some(*v),
        Cond::Absent(k) => !attrs.contains_key(*k),
    })
}

/// 属性の値。未定義のエンティティなどで展開できないときは書かれたままの値を使う
/// (属性ではパースを止めない)。
fn read_attrs(e: &BytesStart) -> HashMap<String, String> {
    e.attributes()
        .with_checks(false)
        .flatten()
        .map(|a| {
            let key = String::from_utf8_lossy(a.key.as_ref()).to_string();
            let value = a
                .unescape_value()
                .map(|v| v.to_string())
                .unwrap_or_else(|_| String::from_utf8_lossy(&a.value).to_string());
            (key, value)
        })
        .collect()
}

fn new_object(class: &'static Class, attrs: &HashMap<String, String>) -> Obj {
    let mut obj = Obj::default();
    for (attr, field) in class.attr_fields {
        if let Some(v) = attrs.get(*attr) {
            obj.set(field, v.clone(), Setter::Plain);
        }
    }
    obj
}

/// 文字参照 (`&#...;`) と定義済みエンティティ (`&amp;` など) を展開する。
/// それ以外 (未定義のエンティティや不正な文字参照) は None。
fn resolve_ref(r: &BytesRef) -> Option<String> {
    match r.resolve_char_ref() {
        Ok(Some(ch)) => Some(ch.to_string()),
        Ok(None) => {
            let name = r.decode().ok()?;
            quick_xml::escape::resolve_predefined_entity(&name).map(str::to_string)
        }
        Err(_) => None,
    }
}

struct Engine {
    stack: Vec<Frame>,
}

impl Engine {
    /// いまの値の入れ先 (いちばん上の Object / Root 区切り) の位置
    fn object_index(&self, upto: usize) -> usize {
        (0..=upto)
            .rev()
            .find(|&i| {
                matches!(
                    self.stack[i].kind,
                    FrameKind::Root | FrameKind::Object { .. }
                )
            })
            .expect("Root は常にスタックの底にある")
    }

    fn start(&mut self, raw_name: &str, attrs: HashMap<String, String>) {
        let name = raw_name.replace('-', "_");
        let top = self.stack.len() - 1;
        let mut obj_idx = self.object_index(top);
        let class = self.stack[obj_idx].class;

        let collection = class.rules.iter().enumerate().find_map(|(idx, r)| match r {
            Rule::Collection { name: n, class, .. } if *n == name => Some((idx, *class)),
            _ => None,
        });
        let pushed_collection = if let Some((idx, child_class)) = collection {
            let obj = new_object(child_class, &attrs);
            self.stack.push(Frame::object(
                FrameKind::Object { rule: idx },
                name.clone(),
                child_class,
                obj,
            ));
            obj_idx = self.stack.len() - 1;
            true
        } else {
            false
        };

        let class = self.stack[obj_idx].class;
        for (idx, rule) in class.rules.iter().enumerate() {
            if let Rule::Attr {
                name: n,
                with,
                attr,
                field,
                setter,
            } = rule
            {
                if *n != name || !conds_match(with, &attrs) {
                    continue;
                }
                let frame = &mut self.stack[obj_idx];
                if frame.parsed.contains(&idx) {
                    continue;
                }
                if let Some(v) = attrs.get(*attr) {
                    frame.obj.set(field, v.clone(), *setter);
                }
                if *setter != Setter::Append {
                    frame.parsed.insert(idx);
                }
            }
        }

        if pushed_collection {
            return;
        }

        let found = class.rules.iter().enumerate().find(|(_, r)| match r {
            Rule::Text { name: n, with, .. } | Rule::Child { name: n, with, .. } => {
                *n == name && conds_match(with, &attrs)
            }
            _ => false,
        });
        match found {
            Some((idx, Rule::Text { .. })) => self.stack.push(Frame::object(
                FrameKind::Text(idx),
                name,
                class,
                Obj::default(),
            )),
            Some((
                idx,
                Rule::Child {
                    class: child_class, ..
                },
            )) => {
                let obj = new_object(child_class, &attrs);
                self.stack.push(Frame::object(
                    FrameKind::Object { rule: idx },
                    name,
                    child_class,
                    obj,
                ));
            }
            _ => {}
        }
    }

    fn characters(&mut self, text: &str) {
        let top = self.stack.last_mut().expect("Root は常にある");
        top.buffer.get_or_insert_with(String::new).push_str(text);
    }

    fn end(&mut self, raw_name: &str) {
        let name = raw_name.replace('-', "_");
        if self.stack.len() < 2 {
            return;
        }
        if self.stack.last().is_none_or(|f| f.name != name) {
            return;
        }
        let close = self.stack.pop().expect("長さは確認済み");
        let parent_idx = self.object_index(self.stack.len() - 1);
        let parent_class = self.stack[parent_idx].class;

        match close.kind {
            FrameKind::Root => {}
            FrameKind::Text(idx) => {
                let parent = &mut self.stack[parent_idx];
                if parent.parsed.contains(&idx) {
                    return;
                }
                if let Rule::Text { field, setter, .. } = &parent_class.rules[idx]
                    && let Some(buf) = close.buffer
                {
                    parent.obj.set(field, buf, *setter);
                }
                parent.parsed.insert(idx);
            }
            FrameKind::Object { rule } => {
                let mut obj = close.obj;
                if let (Some(value_field), Some(buf)) = (close.class.value_field, close.buffer) {
                    obj.set(value_field, buf, Setter::Plain);
                }
                let parent = &mut self.stack[parent_idx];
                match &parent_class.rules[rule] {
                    Rule::Collection { field, .. } => {
                        parent.obj.children.entry(field).or_default().push(obj);
                    }
                    Rule::Child { field, .. } => {
                        if parent.parsed.contains(&rule) {
                            return;
                        }
                        parent.obj.children.insert(field, vec![obj]);
                        parent.parsed.insert(rule);
                    }
                    _ => {}
                }
            }
        }
    }
}

/// XML を読み、root クラスの規則で値を集める。
///
/// Nokogiri の SAX は未定義のエンティティ (`&nbsp;` など) や読めない箇所に出会うとそこで止まる。
/// そのときは開いている区切りを閉じずに捨て、それまでに閉じ終わった値だけを返す
/// (testdata/fixtures/rss_undefined_entity.golden.json)。
pub fn parse(xml: &str, root: &'static Class) -> Obj {
    let mut reader = Reader::from_str(xml.trim_start_matches('\u{feff}'));
    let config = reader.config_mut();
    config.trim_text(false);
    config.expand_empty_elements = true;
    config.check_end_names = false;

    let mut engine = Engine {
        stack: vec![Frame::object(
            FrameKind::Root,
            String::new(),
            root,
            Obj::default(),
        )],
    };

    let completed = loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                let attrs = read_attrs(&e);
                engine.start(&name, attrs);
            }
            Ok(Event::End(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                engine.end(&name);
            }
            // XML 1.0 の改行の正規化 (\r\n → \n) は libxml2 と同じく行う
            Ok(Event::Text(t)) => {
                if let Ok(text) = t.xml10_content() {
                    engine.characters(&text);
                }
            }
            Ok(Event::CData(c)) => {
                if let Ok(text) = c.xml10_content() {
                    engine.characters(&text);
                }
            }
            Ok(Event::GeneralRef(r)) => match resolve_ref(&r) {
                Some(text) => engine.characters(&text),
                None => break false,
            },
            Ok(Event::Eof) => break true,
            Ok(_) => {}
            Err(_) => break false,
        }
    };

    if completed {
        while engine.stack.len() > 1 {
            let name = engine.stack.last().expect("長さは確認済み").name.clone();
            engine.end(&name);
        }
    }
    engine.stack.swap_remove(0).obj
}

#[cfg(test)]
mod tests {
    use super::*;

    static GUID: Class = Class {
        rules: &[],
        value_field: Some("guid"),
        attr_fields: &[("isPermaLink", "is_perma_link")],
    };
    static IMAGE: Class = Class {
        rules: &[],
        value_field: None,
        attr_fields: &[],
    };
    static ENTRY: Class = Class {
        rules: &[
            Rule::Text {
                name: "title",
                with: &[],
                field: "title",
                setter: Setter::Plain,
            },
            Rule::Text {
                name: "pubDate",
                with: &[],
                field: "published",
                setter: Setter::KeepOldest,
            },
            Rule::Child {
                name: "guid",
                with: &[],
                class: &GUID,
                field: "entry_id",
            },
            Rule::Attr {
                name: "link",
                with: &[Cond::Eq("rel", "alternate")],
                attr: "href",
                field: "url",
                setter: Setter::Plain,
            },
            Rule::Attr {
                name: "link",
                with: &[],
                attr: "href",
                field: "links",
                setter: Setter::Append,
            },
            Rule::Text {
                name: "t",
                with: &[Cond::Absent("type")],
                field: "plain_t",
                setter: Setter::Plain,
            },
            Rule::Text {
                name: "t",
                with: &[Cond::Eq("type", "html")],
                field: "html_t",
                setter: Setter::Plain,
            },
            Rule::Text {
                name: "media_title",
                with: &[],
                field: "media_title",
                setter: Setter::Plain,
            },
        ],
        value_field: None,
        attr_fields: &[],
    };
    static FEED: Class = Class {
        rules: &[
            Rule::Text {
                name: "title",
                with: &[],
                field: "title",
                setter: Setter::Plain,
            },
            Rule::Child {
                name: "image",
                with: &[],
                class: &IMAGE,
                field: "image",
            },
            Rule::Collection {
                name: "item",
                class: &ENTRY,
                field: "entries",
            },
        ],
        value_field: None,
        attr_fields: &[],
    };

    #[test]
    fn first_value_wins_per_rule_and_nested_context_is_isolated() {
        let xml = r#"<rss><channel>
            <image><title>image title</title></image>
            <title>Feed</title><title>Second</title>
            <item><title>A</title><guid isPermaLink="false">g1</guid></item>
        </channel></rss>"#;
        let feed = parse(xml, &FEED);
        assert_eq!(feed.get("title"), Some("Feed"));
        let entry = &feed.list("entries")[0];
        assert_eq!(entry.get("title"), Some("A"));
        let guid = entry.child("entry_id").unwrap();
        assert_eq!(guid.get("guid"), Some("g1"));
        assert_eq!(guid.get("is_perma_link"), Some("false"));
    }

    #[test]
    fn attr_rules_cdata_entities_and_keep_oldest() {
        let xml = r#"<rss><item>
            <title><![CDATA[<b>x</b>]]> &amp; y</title>
            <link rel="alternate" href="https://e/1"/><link href="https://e/2"/>
            <pubDate>Wed, 24 Sep 2026 11:00:00 +0000</pubDate>
            <pubDate>Wed, 24 Sep 2026 09:00:00 +0000</pubDate>
            <t>plain</t><t type="html">html</t>
        </item></rss>"#;
        let feed = parse(xml, &FEED);
        let entry = &feed.list("entries")[0];
        assert_eq!(entry.get("title"), Some("<b>x</b> & y"));
        assert_eq!(entry.get("url"), Some("https://e/1"));
        assert_eq!(
            entry.all("links"),
            &["https://e/1".to_string(), "https://e/2".to_string()]
        );
        // 同じルールは最初の1回だけ (2つ目の pubDate は無視される)
        assert_eq!(entry.get("published"), Some("2026-09-24T11:00:00+00:00"));
        assert_eq!(entry.get("plain_t"), Some("plain"));
        assert_eq!(entry.get("html_t"), Some("html"));
    }

    #[test]
    fn empty_element_marks_rule_as_done_without_value() {
        let xml = "<rss><item><title></title><title>later</title></item></rss>";
        let feed = parse(xml, &FEED);
        assert_eq!(feed.list("entries")[0].get("title"), None);
    }

    #[test]
    fn hyphens_in_element_names_match_underscore_rules() {
        let xml = "<rss><item><media-title>m</media-title></item></rss>";
        let feed = parse(xml, &FEED);
        assert_eq!(feed.list("entries")[0].get("media_title"), Some("m"));
    }

    #[test]
    fn predefined_and_numeric_entities_decode_and_parsing_continues() {
        let xml = "<rss><item><title>a &amp; &#x3042;&#12354;</title></item><item><title>b</title></item></rss>";
        let feed = parse(xml, &FEED);
        let entries = feed.list("entries");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].get("title"), Some("a & ああ"));
        assert_eq!(entries[1].get("title"), Some("b"));
    }

    #[test]
    fn undefined_entity_stops_parsing_and_discards_open_frames() {
        // Nokogiri SAX は未定義のエンティティで止まる。その item と以降は失われる
        // (testdata/fixtures/rss_undefined_entity.golden.json)
        let xml = "<rss><item><title>a</title></item><item><title>b&nbsp;c</title></item><item><title>d</title></item></rss>";
        let feed = parse(xml, &FEED);
        let entries = feed.list("entries");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].get("title"), Some("a"));
    }

    #[test]
    fn root_fields_completed_before_fatal_error_survive() {
        let xml =
            "<rss><channel><title>Feed</title><item><title>x&bogus;</title></item></channel></rss>";
        let feed = parse(xml, &FEED);
        assert_eq!(feed.get("title"), Some("Feed"));
        assert!(feed.list("entries").is_empty());
    }

    #[test]
    fn undefined_entity_in_attribute_falls_back_to_raw_value() {
        let xml = r#"<rss><item><link href="https://e/?a=1&nbsp;b"/><title>t</title></item></rss>"#;
        let feed = parse(xml, &FEED);
        let entry = &feed.list("entries")[0];
        assert_eq!(entry.all("links"), &["https://e/?a=1&nbsp;b".to_string()]);
        assert_eq!(entry.get("title"), Some("t"));
    }
}
