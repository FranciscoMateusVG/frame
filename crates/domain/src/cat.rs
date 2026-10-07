use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub type CatId = String;
pub type CatName = String;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cat {
    pub id: CatId,
    pub name: CatName,
    #[serde(serialize_with = "serialize_timestamp")]
    pub created_at: DateTime<Utc>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateCatInput {
    pub id: String,
    pub name: String,
}

/// ECMAScript String.trim whitespace (not Rust's Unicode White_Space set).
pub fn trim_name(name: &str) -> &str {
    name.trim_matches(|c| matches!(c, '\u{0009}'..='\u{000d}' | '\u{0020}' | '\u{00a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}'))
}

/// JS/Zod counts UTF-16 code units, not UTF-8 bytes or Unicode scalar values.
pub fn name_length(name: &str) -> usize {
    name.encode_utf16().count()
}

pub fn parse_cat_name(name: &str) -> Result<String, String> {
    let name = trim_name(name);
    if name.is_empty() {
        Err("Cat name must not be empty".into())
    } else if name_length(name) > 100 {
        Err("Cat name must be 100 characters or fewer".into())
    } else {
        Ok(name.into())
    }
}

/// Matches Zod z.uuid(): RFC variant, versions 1–8, plus nil/max UUIDs.
/// Preserve caller casing; the Postgres adapter canonicalizes it on reading.
pub fn parse_cat_id(id: &str) -> Result<String, String> {
    let bytes = id.as_bytes();
    let shape = bytes.len() == 36
        && bytes.iter().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                *b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        });
    let valid = shape
        && (id == "00000000-0000-0000-0000-000000000000"
            || id.eq_ignore_ascii_case("ffffffff-ffff-ffff-ffff-ffffffffffff")
            || (matches!(bytes[14], b'1'..=b'8')
                && matches!(bytes[19], b'8' | b'9' | b'a' | b'b' | b'A' | b'B')));
    if valid {
        Ok(id.into())
    } else {
        Err("Invalid UUID".into())
    }
}

pub fn parse_create_cat_input(input: CreateCatInput) -> Result<CreateCatInput, String> {
    let id = parse_cat_id(&input.id);
    let name = parse_cat_name(&input.name);
    match (id, name) {
        (Ok(id), Ok(name)) => Ok(CreateCatInput { id, name }),
        (Err(id), Err(name)) => Err(format!("{id}; {name}")),
        (Err(error), _) | (_, Err(error)) => Err(error),
    }
}

/// Untyped boundary counterpart of CreateCatInputSchema.safeParse.
pub fn parse_create_cat_value(value: serde_json::Value) -> Result<CreateCatInput, String> {
    let input = serde_json::from_value(value).map_err(|e| e.to_string())?;
    parse_create_cat_input(input)
}

pub type Timestamp = DateTime<Utc>;

fn serialize_timestamp<S: serde::Serializer>(
    timestamp: &DateTime<Utc>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&timestamp.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
}
