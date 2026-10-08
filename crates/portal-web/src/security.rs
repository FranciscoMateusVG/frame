//! Browser-facing security primitives: `__Host-` cookies, exact-Origin and
//! CSRF checks, random identifiers, client address with explicit proxy
//! trust, and the response headers every page carries.
use axum::http::{HeaderMap, HeaderValue, header};
use frame_portal_use_cases::tokens_match;
use std::net::{IpAddr, SocketAddr};

pub const SESSION_COOKIE: &str = "__Host-print_session";
pub const PRESESSION_COOKIE: &str = "__Host-print_presession";
pub const CSRF_HEADER: &str = "x-csrf-token";

/// 256 random bits, hex-encoded.
pub fn random_id() -> String {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).expect("operating system RNG available");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// First value of a cookie; ids are hex, anything else is ignored.
pub fn cookie(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .filter_map(|pair| pair.trim().split_once('='))
        .find(|(k, _)| *k == name)
        .map(|(_, v)| v.to_owned())
        .filter(|v| v.len() == 64 && v.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// Host-only (no Domain), Secure, HttpOnly, SameSite=Lax, Path=/.
pub fn set_cookie(name: &str, value: &str, max_age_seconds: i64) -> HeaderValue {
    HeaderValue::from_str(&format!(
        "{name}={value}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age={max_age_seconds}"
    ))
    .expect("cookie is a valid header value")
}

pub fn clear_cookie(name: &str) -> HeaderValue {
    set_cookie(name, "", 0)
}

/// Exact `Origin` match; an absent Origin always fails (no CORS anywhere).
pub fn origin_ok(headers: &HeaderMap, expected: &str) -> bool {
    headers
        .get(header::ORIGIN)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v == expected)
}

pub fn csrf_ok(headers: &HeaderMap, expected_origin: &str, csrf: &str) -> bool {
    origin_ok(headers, expected_origin)
        && headers
            .get(CSRF_HEADER)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| tokens_match(v, csrf))
}

/// The socket peer, unless it is an explicitly trusted proxy: then the
/// right-most `X-Forwarded-For` hop that is not itself trusted. A client's
/// own `X-Forwarded-For` is never believed.
pub fn client_ip(headers: &HeaderMap, peer: SocketAddr, trusted: &[IpAddr]) -> IpAddr {
    let peer = peer.ip().to_canonical();
    if !trusted.contains(&peer) {
        return peer;
    }
    let hops: Vec<IpAddr> = headers
        .get_all("x-forwarded-for")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .filter_map(|s| s.trim().parse::<IpAddr>().ok())
        .map(|ip| ip.to_canonical())
        .collect();
    hops.into_iter()
        .rev()
        .find(|ip| !trusted.contains(ip))
        .unwrap_or(peer)
}

pub const PAGE_CSP: &str = "default-src 'none'; script-src 'self'; style-src 'self'; \
     img-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";
pub const DOWNLOAD_CSP: &str = "sandbox; default-src 'none'";

/// Headers on every response; pages and downloads add their own CSP.
pub fn harden(headers: &mut HeaderMap) {
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    headers.insert(header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
    if !headers.contains_key(header::CONTENT_SECURITY_POLICY) {
        headers.insert(
            header::CONTENT_SECURITY_POLICY,
            HeaderValue::from_static(PAGE_CSP),
        );
    }
    if !headers.contains_key(header::CACHE_CONTROL) {
        headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    }
}
