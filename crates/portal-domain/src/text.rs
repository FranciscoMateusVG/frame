//! Text shapes shared by the DTOs and the BFF boundary.

/// Canonical 8-4-4-4-12 hex UUID (any version), as the upstream accepts.
pub fn is_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(i, b)| match i {
            8 | 13 | 18 | 23 => *b == b'-',
            _ => b.is_ascii_hexdigit(),
        })
}

/// Lowercase 64-character hex digest.
pub fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// UTF-16 length, the unit the upstream (Zod/JS) counts string limits in.
pub fn utf16_len(value: &str) -> usize {
    value.encode_utf16().count()
}

/// Last path segment, no control characters, at most 200 chars; never empty.
/// Mirrors the upstream rule so a hostile name cannot reach a header.
pub fn sanitize_download_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let clean: String = base.chars().filter(|c| !c.is_control()).collect();
    let clean: String = clean.trim().chars().take(200).collect();
    if clean.is_empty() || clean == "." || clean == ".." {
        "arquivo".into()
    } else {
        clean
    }
}

/// `attachment` disposition with an ASCII fallback and an RFC 5987 UTF-8 name.
pub fn content_disposition(name: &str) -> String {
    let name = sanitize_download_name(name);
    let ascii: String = name
        .chars()
        .map(|c| match c {
            '"' | '\\' | ';' => '_',
            c if (' '..='~').contains(&c) => c,
            _ => '_',
        })
        .collect();
    format!(
        "attachment; filename=\"{ascii}\"; filename*=UTF-8''{}",
        percent_encode(&name)
    )
}

/// Percent-encodes everything outside RFC 3986 unreserved characters.
pub fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for b in value.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Inverse of [`percent_encode`]; `None` for malformed escapes or non-UTF-8.
pub fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// File name carried by a `Content-Disposition` header (RFC 5987 form first).
pub fn disposition_filename(header: &str) -> Option<String> {
    let mut plain = None;
    for part in header.split(';').map(str::trim) {
        if let Some(encoded) = part.strip_prefix("filename*=UTF-8''") {
            return percent_decode(encoded);
        }
        if let Some(quoted) = part.strip_prefix("filename=") {
            plain = Some(quoted.trim_matches('"').to_owned());
        }
    }
    plain
}
