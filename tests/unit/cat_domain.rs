use frame_domain::{parse_cat_id, parse_cat_name, parse_create_cat_value};
use serde_json::json;

#[test]
fn accepts_valid_name() {
    assert_eq!(parse_cat_name("Whiskers").unwrap(), "Whiskers");
}
#[test]
fn rejects_empty_name() {
    assert!(parse_cat_name("").is_err());
}
#[test]
fn rejects_101_characters() {
    assert!(parse_cat_name(&"a".repeat(101)).is_err());
}
#[test]
fn accepts_100_characters() {
    assert!(parse_cat_name(&"a".repeat(100)).is_ok());
}
#[test]
fn trims_whitespace() {
    assert_eq!(parse_cat_name("  Luna  ").unwrap(), "Luna");
}
#[test]
fn accepts_single_character() {
    assert!(parse_cat_name("X").is_ok());
}
#[test]
fn rejects_whitespace_only() {
    assert!(parse_cat_name("   ").is_err());
}
#[test]
fn accepts_uuid_v4() {
    assert!(parse_cat_id("550e8400-e29b-41d4-a716-446655440000").is_ok());
}
#[test]
fn rejects_malformed_uuid() {
    assert!(parse_cat_id("not-a-uuid").is_err());
}
#[test]
fn rejects_empty_uuid() {
    assert!(parse_cat_id("").is_err());
}
#[test]
fn accepts_valid_input() {
    assert!(
        parse_create_cat_value(
            json!({"id":"550e8400-e29b-41d4-a716-446655440000", "name":"Whiskers"})
        )
        .is_ok()
    );
}
#[test]
fn rejects_missing_name() {
    assert!(parse_create_cat_value(json!({"id":"550e8400-e29b-41d4-a716-446655440000"})).is_err());
}
#[test]
fn rejects_missing_id() {
    assert!(parse_create_cat_value(json!({"name":"Whiskers"})).is_err());
}

#[test]
fn matches_ecmascript_utf16_length_and_trim() {
    assert!(parse_cat_name(&"🐱".repeat(50)).is_ok());
    assert!(parse_cat_name(&"🐱".repeat(51)).is_err());
    assert_eq!(parse_cat_name("\u{feff}Luna\u{feff}").unwrap(), "Luna");
    // Rust trim removes NEL; JavaScript trim does not.
    assert_eq!(parse_cat_name("\u{85}").unwrap(), "\u{85}");
}
#[test]
fn uuid_schema_matches_zod_rfc_versions_nil_and_max() {
    for version in 1..=8 {
        assert!(parse_cat_id(&format!("550e8400-e29b-{version}1d4-a716-446655440000")).is_ok());
    }
    for id in [
        "00000000-0000-0000-0000-000000000000",
        "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
    ] {
        assert_eq!(parse_cat_id(id).unwrap(), id);
    }
    for id in [
        "550e8400e29b41d4a716446655440000",
        "550e8400-e29b-91d4-a716-446655440000",
        "550e8400-e29b-41d4-1716-446655440000",
        "550e8400-e29b-41d4-g716-446655440000",
    ] {
        assert!(parse_cat_id(id).is_err());
    }
}
#[test]
fn aggregates_id_and_name_issues_in_order() {
    let error = parse_create_cat_value(json!({"id":"bad", "name":""})).unwrap_err();
    assert_eq!(error, "Invalid UUID; Cat name must not be empty");
}

#[test]
fn entities_and_input_serialize_with_ts_json_shape() {
    let cat = frame_domain::Cat {
        id: "550e8400-e29b-41d4-a716-446655440000".into(),
        name: "Whiskers".into(),
        created_at: "2026-01-15T12:00:00Z".parse().unwrap(),
    };
    let value = serde_json::to_value(&cat).unwrap();
    assert_eq!(value["createdAt"], "2026-01-15T12:00:00.000Z");
    assert_eq!(
        serde_json::from_value::<frame_domain::Cat>(value).unwrap(),
        cat
    );
    let input = frame_domain::CreateCatInput {
        id: cat.id,
        name: cat.name,
    };
    assert_eq!(
        parse_create_cat_value(serde_json::to_value(&input).unwrap()).unwrap(),
        input
    );
}
