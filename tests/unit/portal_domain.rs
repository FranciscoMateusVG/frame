use crate::portal_api_conformance::FIXTURE;
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
fn every_frozen_v2_fixture_body_parses_strictly_and_reserializes_unchanged() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    let batches = fixture["batches"].as_array().unwrap();
    assert_eq!(batches.len(), 8);
    for batch in batches {
        roundtrip::<BatchResponse>(&serde_json::json!({ "batch": batch }));
        roundtrip::<OpenBatchResponse>(&serde_json::json!({ "batch": batch }));
        let summary: Batch = serde_json::from_value(batch.clone()).unwrap();
        roundtrip::<BatchList>(&serde_json::json!({
            "items": [serde_json::to_value(summary.summary()).unwrap()],
            "nextCursor": null,
        }));
    }
    roundtrip::<BatchResponse>(&fixture["nextBatch"]);
    roundtrip::<BatchResponse>(&fixture["rebatchedBatch"]);
    roundtrip::<OpenBatchResponse>(&serde_json::json!({ "batch": null }));
    roundtrip::<CloseResponse>(&fixture["monthlyClose"]);
    let close: CloseResponse = serde_json::from_value(fixture["monthlyClose"].clone()).unwrap();
    assert!(close.close.accepts_invoice());
    assert_eq!(close.close.items[0].reference(), "LOT-0001");
    assert_eq!(close.close.items[1].reference(), "IMP-0301");
}

#[test]
fn unknown_fields_and_schema_violations_are_rejected() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    let base = serde_json::json!({ "batch": fixture["rebatchedBatch"]["batch"].clone() });
    let mutate = |f: &dyn Fn(&mut Value)| {
        let mut v = base.clone();
        f(&mut v);
        serde_json::from_value::<BatchResponse>(v)
            .map_err(|_| ())
            .and_then(|r| r.validate().map_err(|_| ()))
    };
    assert!(mutate(&|_| {}).is_ok());
    // Unknown field (e.g. a leaked bucket key) anywhere is a contract break.
    assert!(mutate(&|v| v["batch"]["items"][0]["jobs"][0]["file"]["bucket"] = "x".into()).is_err());
    assert!(mutate(&|v| v["batch"]["supplierId"] = "x".into()).is_err());
    assert!(mutate(&|v| v["batch"]["status"] = "ready".into()).is_err());
    assert!(mutate(&|v| v["batch"]["reference"] = "IMP-0001".into()).is_err());
    assert!(mutate(&|v| v["batch"]["items"][0]["reference"] = "LOT-0001".into()).is_err());
    assert!(
        mutate(&|v| v["batch"]["items"][0]["previouslyCancelledIn"] = "IMP-0001".into()).is_err()
    );
    assert!(mutate(&|v| v["batch"]["items"][0]["previouslyCancelledIn"] = Value::Null).is_err());
    assert!(mutate(&|v| v["batch"]["items"][0]["generalInstructions"] = Value::Null).is_err());
    assert!(mutate(&|v| v["batch"]["itemCount"] = 3.into()).is_err());
    assert!(
        mutate(&|v| v["batch"]["items"][1]["orderId"] = v["batch"]["items"][0]["orderId"].clone())
            .is_err()
    );
    assert!(mutate(&|v| v["batch"]["items"][0]["jobs"][0]["copies"] = 501.into()).is_err());
    assert!(mutate(&|v| v["batch"]["items"][0]["jobs"][0]["copies"] = 2.5.into()).is_err());
    assert!(
        mutate(&|v| v["batch"]["items"][0]["jobs"][0]["file"]["sha256"] = "ABC".into()).is_err()
    );
    assert!(mutate(&|v| v["batch"]["createdAt"] = "2026-10-08T02:36:51.147+01:00".into()).is_err());
    assert!(mutate(&|v| v["batch"]["approvedAmountCents"] = 2_147_483_648i64.into()).is_err());
    assert!(mutate(&|v| v["batch"]["id"] = "not-a-uuid".into()).is_err());
    // Each file once per item, and at least one file.
    assert!(
        mutate(&|v| {
            let dup = v["batch"]["items"][0]["jobs"][0]["file"].clone();
            v["batch"]["items"][0]["generalInstructions"]["files"][0] = dup;
        })
        .is_err()
    );
    assert!(mutate(&|v| v["batch"]["items"][1]["jobs"] = serde_json::json!([])).is_err());
    let close = fixture["monthlyClose"].clone();
    let mut bad = close.clone();
    bad["close"]["items"][0]["kind"] = "order".into();
    assert!(serde_json::from_value::<CloseResponse>(bad).is_err());
    let mut bad = close;
    bad["close"]["items"][1]["batchId"] = bad["close"]["items"][1]["orderId"].clone();
    assert!(serde_json::from_value::<CloseResponse>(bad).is_err());
}

#[test]
fn mixed_jobs_and_residual_instructions_are_valid_and_kept_apart() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    let open: Batch = serde_json::from_value(fixture["batches"][0].clone()).unwrap();
    let item = &open.items[0];
    assert_eq!(item.jobs.len(), 2);
    let general = item.general_instructions.as_ref().unwrap();
    assert!(general.text.starts_with("Orientação geral"));
    let ids: Vec<&str> = item.files().map(|f| f.id.as_str()).collect();
    assert_eq!(
        ids,
        [
            "00000000-0000-4000-8000-00000000000b",
            "00000000-0000-4000-8000-00000000000c",
            "00000000-0000-4000-8000-00000000000d"
        ],
        "jobs first, then residual files"
    );
    assert_eq!(open.copies(), 36);
    // Text-only and files-only residuals are both valid.
    let mut text_only = fixture["batches"][0].clone();
    text_only["items"][0]["generalInstructions"]["files"] = serde_json::json!([]);
    roundtrip::<BatchResponse>(&serde_json::json!({ "batch": text_only }));
}

#[test]
fn batch_status_progress_and_current_set() {
    assert_eq!(
        BatchStatus::parse("quote_rejected"),
        Some(BatchStatus::QuoteRejected)
    );
    assert_eq!(BatchStatus::parse("ready"), None);
    let steps: Vec<_> = BatchStatus::ALL.iter().map(|s| s.progress()).collect();
    assert_eq!(
        steps,
        [
            Some(0),
            Some(1),
            Some(2),
            Some(2),
            Some(3),
            Some(4),
            None,
            None
        ]
    );
    assert_eq!(BATCH_STEPS.len(), 5);
    assert!(BatchStatus::Printed.is_current() && !BatchStatus::Received.is_current());
    for status in BatchStatus::ALL {
        assert_eq!(BatchStatus::parse(status.as_str()), Some(status));
    }
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
    assert_eq!(utf16_len("😀"), 2);
}
