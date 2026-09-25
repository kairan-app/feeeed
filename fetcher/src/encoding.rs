/// HTTP のレスポンスを UTF-8 として解釈し、不正なバイト列は取り除く。
/// Rails の `force_encoding("UTF-8").encode("UTF-8", invalid: :replace, replace: "")` と同じ。
pub fn to_utf8_dropping_invalid(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len());
    for chunk in bytes.utf8_chunks() {
        out.push_str(chunk.valid());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_invalid_bytes_and_keeps_valid_text() {
        assert_eq!(to_utf8_dropping_invalid(b"a\xff\xfeb\xc3\x28c"), "ab(c");
        assert_eq!(to_utf8_dropping_invalid("日本語".as_bytes()), "日本語");
    }
}
