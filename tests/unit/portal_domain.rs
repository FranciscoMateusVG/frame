use crate::portal_fixtures::{MONTHLY_CLOSES, ORDERS};
use chrono::{TimeZone, Utc};
use frame_portal_domain::*;
use serde_json::Value;

fn roundtrip<T: serde::de::DeserializeOwned + serde::Serialize + Validate>(body: &Value) {
    let parsed: T = serde_json::from_value(body.clone()).expect("fixture parses strictly");
    parsed
        .validate()
        .expect("fixture satisfies schema constraints");
    assert_eq!(
        &serde_json::to_value(&parsed).unwrap(),
        body,
        "pass-through is lossless"
    );
}

#[test]
fn every_frozen_order_fixture_parses_strictly_and_reserializes_unchanged() {
    let fixture: Value = serde_json::from_str(ORDERS).unwrap();
    roundtrip::<OrderList>(&fixture["GET /orders"]);
    for key in [
        "GET /orders/:id (ready)",
        "POST /orders/:id/collected",
        "POST /orders/:id/quotes",
        "POST /orders/:id/printed",
    ] {
        roundtrip::<OrderResponse>(&fixture[key]);
    }
}

#[test]
fn every_frozen_close_fixture_parses_strictly_and_reserializes_unchanged() {
    let fixture: Value = serde_json::from_str(MONTHLY_CLOSES).unwrap();
    let bodies = fixture["bodies"].as_object().unwrap();
    assert_eq!(bodies.len(), 6);
    for body in bodies.values() {
        roundtrip::<CloseResponse>(body);
    }
    let accepted: CloseResponse = serde_json::from_value(
        bodies["GET /monthly-closes/:competence (open, period closed)"].clone(),
    )
    .unwrap();
    assert!(accepted.close.accepts_invoice());
    let virtual_open: CloseResponse = serde_json::from_value(
        bodies["GET /monthly-closes/:competence (current month, period open)"].clone(),
    )
    .unwrap();
    assert!(!virtual_open.close.accepts_invoice());
}

#[test]
fn unknown_fields_and_schema_violations_are_rejected() {
    let fixture: Value = serde_json::from_str(ORDERS).unwrap();
    let base = fixture["GET /orders/:id (ready)"].clone();
    let mutate = |f: &dyn Fn(&mut Value)| {
        let mut v = base.clone();
        f(&mut v);
        serde_json::from_value::<OrderResponse>(v)
            .map_err(|_| ())
            .and_then(|r| r.validate().map_err(|_| ()))
    };
    assert!(mutate(&|_| {}).is_ok());
    // Unknown field (e.g. a leaked bucket key) anywhere is a contract break.
    assert!(mutate(&|v| v["order"]["jobs"][0]["file"]["bucket"] = "solicitations".into()).is_err());
    assert!(mutate(&|v| v["order"]["requester"] = "x".into()).is_err());
    assert!(mutate(&|v| v["order"]["status"] = "needs_review".into()).is_err());
    assert!(mutate(&|v| v["order"]["reference"] = "P-1".into()).is_err());
    assert!(mutate(&|v| v["order"]["jobs"][0]["copies"] = 501.into()).is_err());
    assert!(mutate(&|v| v["order"]["jobs"][0]["copies"] = 2.5.into()).is_err());
    assert!(mutate(&|v| v["order"]["jobs"][0]["file"]["sha256"] = "ABC".into()).is_err());
    assert!(mutate(&|v| v["order"]["jobs"] = Value::Array(vec![])).is_err());
    assert!(mutate(&|v| v["order"]["createdAt"] = "2026-10-08T02:36:51.147+01:00".into()).is_err());
    assert!(mutate(&|v| v["order"]["approvedAmountCents"] = 2_147_483_648i64.into()).is_err());
    assert!(mutate(&|v| v["order"]["id"] = "not-a-uuid".into()).is_err());
}

#[test]
fn cents_and_revisions_accept_only_canonical_integers() {
    assert_eq!(parse_cents("45900"), Some(45_900));
    assert_eq!(parse_cents("2147483647"), Some(MAX_CENTS));
    for bad in [
        "",
        "0",
        "045",
        "-1",
        "1.5",
        "2147483648",
        "99999999999",
        " 1",
        "1e3",
    ] {
        assert_eq!(parse_cents(bad), None, "{bad:?}");
    }
    assert_eq!(parse_revision("3"), Some(3));
    for bad in ["", "0", "01", "x", "1234567890"] {
        assert_eq!(parse_revision(bad), None, "{bad:?}");
    }
}

#[test]
fn brl_is_formatted_and_parsed_the_brazilian_way() {
    assert_eq!(format_brl(45_900), "R$ 459,00");
    assert_eq!(format_brl(123_456_789), "R$ 1.234.567,89");
    assert_eq!(format_brl(5), "R$ 0,05");
    assert_eq!(parse_brl("459"), Some(45_900));
    assert_eq!(parse_brl("459,9"), Some(45_990));
    assert_eq!(parse_brl("R$ 1.234,56"), Some(123_456));
    assert_eq!(parse_brl("  12,05 "), Some(1_205));
    for bad in [
        "",
        "0",
        "0,00",
        "45.90",
        "1.23,00",
        "12,345",
        "abc",
        "-5",
        "1,",
        "999999999",
    ] {
        assert_eq!(parse_brl(bad), None, "{bad:?}");
    }
}

#[test]
fn competence_is_a_sao_paulo_month() {
    assert_eq!(Competence::parse("2026-09").unwrap().to_string(), "2026-09");
    for bad in [
        "2026-9",
        "2026-13",
        "2026-00",
        "26-09",
        "2026/09",
        "1999-01",
        "2026-09-01",
    ] {
        assert!(Competence::parse(bad).is_none(), "{bad}");
    }
    // 02:59Z on Oct 1st is still September in São Paulo (UTC−3).
    let late = Utc.with_ymd_and_hms(2026, 10, 1, 2, 59, 0).unwrap();
    assert_eq!(Competence::containing(late).to_string(), "2026-09");
    let sep = Competence::parse("2026-09").unwrap();
    assert_eq!(
        sep.ends_at(),
        Utc.with_ymd_and_hms(2026, 10, 1, 3, 0, 0).unwrap()
    );
    assert!(!sep.is_closed(late));
    assert!(sep.is_closed(sep.ends_at()));
    assert_eq!(
        Competence::parse("2026-01").unwrap().previous().to_string(),
        "2025-12"
    );
    assert_eq!(
        Competence::parse("2026-12").unwrap().next().to_string(),
        "2027-01"
    );
    assert_eq!(sep.label(), "setembro de 2026");
}

#[test]
fn download_names_cannot_reach_paths_or_headers() {
    assert_eq!(sanitize_download_name("../../etc/passwd"), "passwd");
    assert_eq!(sanitize_download_name("C:\\x\\nf.pdf"), "nf.pdf");
    assert_eq!(
        sanitize_download_name("a\r\nSet-Cookie: x.pdf"),
        "aSet-Cookie: x.pdf"
    );
    assert_eq!(sanitize_download_name(".."), "arquivo");
    assert_eq!(sanitize_download_name(""), "arquivo");
    let header = content_disposition("física \"final\";.pdf");
    assert_eq!(
        header,
        "attachment; filename=\"f_sica _final__.pdf\"; filename*=UTF-8''f%C3%ADsica%20%22final%22%3B.pdf"
    );
    assert_eq!(
        disposition_filename(&header).as_deref(),
        Some("física \"final\";.pdf")
    );
    assert_eq!(
        disposition_filename("attachment; filename=\"plain.pdf\"").as_deref(),
        Some("plain.pdf")
    );
    assert_eq!(percent_decode("%ZZ"), None);
}

#[test]
fn ids_and_digests_have_exact_shapes() {
    assert!(is_uuid("6b8337b0-4dbc-4c1f-8644-9691aa494c21"));
    assert!(!is_uuid("6b8337b0-4dbc-4c1f-8644-9691aa494c2"));
    assert!(!is_uuid("6b8337b0x4dbc-4c1f-8644-9691aa494c21"));
    assert!(!is_uuid("../../../../../../../../../../../../"));
    assert!(is_sha256_hex(&"a".repeat(64)));
    assert!(!is_sha256_hex(&"A".repeat(64)));
    assert_eq!(
        OrderStatus::parse("quote_pending"),
        Some(OrderStatus::QuotePending)
    );
    assert_eq!(OrderStatus::parse("awaiting_readiness"), None);
    assert_eq!(utf16_len("😀"), 2);
}

#[test]
fn general_instructions_roundtrip_and_exclusive_modes() {
    let fixture: Value = serde_json::from_str(ORDERS).unwrap();
    let original = fixture["GET /orders/:id (ready)"].clone();
    let mut legacy = original.clone();
    let files: Vec<Value> = original["order"]["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|j| j["file"].clone())
        .collect();
    legacy["order"]["generalInstructions"] =
        serde_json::json!({"text": "Texto integral\nSem vínculo", "files": files});
    legacy["order"]["jobs"] = serde_json::json!([]);
    roundtrip::<OrderResponse>(&legacy);
    for general in [
        Value::Null,
        serde_json::json!({"text":"x","files":[]}),
        serde_json::json!({"text":7,"files":files}),
        serde_json::json!({"text":"x","files":files,"bucket":"private"}),
        serde_json::json!({"text":"x","files":[{}]}),
    ] {
        let mut bad = legacy.clone();
        bad["order"]["generalInstructions"] = general;
        assert!(
            serde_json::from_value::<OrderResponse>(bad)
                .map_err(|_| ())
                .and_then(|r| r.validate().map_err(|_| ()))
                .is_err()
        );
    }
    legacy["order"]["jobs"] = original["order"]["jobs"].clone();
    assert!(
        serde_json::from_value::<OrderResponse>(legacy)
            .map_err(|_| ())
            .and_then(|r| r.validate().map_err(|_| ()))
            .is_err()
    );
}
