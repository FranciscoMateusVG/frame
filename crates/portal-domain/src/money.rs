//! Integer BRL cents. No floats anywhere on the money path.

/// Postgres int4, the upstream ceiling for any amount (sums included).
pub const MAX_CENTS: i64 = 2_147_483_647;

/// Canonical decimal string of an integer in `1..=MAX_CENTS` (no sign, no
/// leading zero), exactly the multipart field format the upstream accepts.
pub fn parse_cents(raw: &str) -> Option<i64> {
    if raw.is_empty()
        || raw.len() > 10
        || raw.starts_with('0')
        || !raw.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    raw.parse::<i64>().ok().filter(|n| *n <= MAX_CENTS)
}

/// Canonical decimal string of a positive revision number.
pub fn parse_revision(raw: &str) -> Option<u64> {
    if raw.is_empty()
        || raw.len() > 9
        || raw.starts_with('0')
        || !raw.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    raw.parse().ok()
}

/// Brazilian display format: `R$ 1.234,56`.
pub fn format_brl(cents: i64) -> String {
    let sign = if cents < 0 { "-" } else { "" };
    let abs = cents.unsigned_abs();
    let reais = (abs / 100).to_string();
    let mut grouped = String::new();
    for (i, c) in reais.chars().enumerate() {
        if i > 0 && (reais.len() - i).is_multiple_of(3) {
            grouped.push('.');
        }
        grouped.push(c);
    }
    format!("{sign}R$ {grouped},{:02}", abs % 100)
}

/// Parses what a person types as a BRL value (`1.234,56`, `459`, `R$ 12,5`)
/// into cents. Comma is the only decimal separator; dots only group
/// thousands, so `45.90` is rejected rather than guessed.
pub fn parse_brl(input: &str) -> Option<i64> {
    let s = input.trim();
    let s = s.strip_prefix("R$").unwrap_or(s).trim();
    let (int_part, frac) = match s.split_once(',') {
        Some((i, f)) if !f.is_empty() && f.len() <= 2 && f.bytes().all(|b| b.is_ascii_digit()) => {
            (i, f)
        }
        Some(_) => return None,
        None => (s, ""),
    };
    let digits = if int_part.contains('.') {
        let groups: Vec<&str> = int_part.split('.').collect();
        let head_ok = (1..=3).contains(&groups[0].len());
        let rest_ok = groups[1..].iter().all(|g| g.len() == 3);
        if !head_ok || !rest_ok {
            return None;
        }
        groups.concat()
    } else {
        int_part.to_owned()
    };
    if digits.is_empty() || digits.len() > 8 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let reais: i64 = digits.parse().ok()?;
    let cents: i64 = match frac.len() {
        0 => 0,
        1 => frac.parse::<i64>().ok()? * 10,
        _ => frac.parse().ok()?,
    };
    let total = reais.checked_mul(100)?.checked_add(cents)?;
    (1..=MAX_CENTS).contains(&total).then_some(total)
}
