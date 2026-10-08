use crate::portal_api_conformance::{SPANS, TestClock, run};
use crate::portal_fake_hono::{FakeHono, TOKEN};
use frame_portal_hono::{PrintApiHono, Timeouts, parse_origin};
use frame_portal_memory::PrintApiMemory;
use frame_portal_port::{ApiError, ListQuery, PrintApi};
use std::{sync::Arc, time::Duration};

#[tokio::test]
async fn http_adapter_satisfies_the_print_api_contract_over_a_real_socket() {
    let obs = frame_testing::TestObservability::new();
    let clock = TestClock::at(2026, 9, 10);
    let fake = Arc::new(PrintApiMemory::new(clock.as_fn()));
    let upstream = FakeHono::start(fake.clone()).await;
    let adapter = PrintApiHono::new(&upstream.origin, TOKEN, Timeouts::default()).unwrap();
    run(&adapter, &fake, &clock).await;
    let spans = obs.get_spans();
    for name in SPANS {
        let span = spans
            .iter()
            .find(|s| {
                s.name == *name
                    && s.attributes
                        .iter()
                        .any(|kv| kv.value.as_str() == frame_portal_hono::SYSTEM)
            })
            .unwrap_or_else(|| panic!("missing adapter span {name}"));
        assert!(
            span.attributes
                .iter()
                .any(|kv| kv.key.as_str() == "http.response.status_code"),
            "{name} records the upstream status"
        );
    }
}

fn unavailable(result: Result<impl std::fmt::Debug, ApiError>) -> &'static str {
    match result {
        Err(ApiError::Unavailable { reason }) => reason,
        other => panic!("expected Unavailable, got {other:?}"),
    }
}

#[tokio::test]
async fn credential_redirect_timeout_and_contract_breaks_are_unavailable() {
    let fake = Arc::new(PrintApiMemory::default());
    fake.seed_order(
        "Pedido",
        vec![crate::portal_api_conformance::job(
            "Folha",
            1,
            "A4 simples",
            "a.pdf",
            crate::portal_api_conformance::PDF_A,
        )],
    );
    let upstream = FakeHono::start(fake.clone()).await;
    let timeouts = Timeouts {
        json: Duration::from_millis(300),
        ..Timeouts::default()
    };
    let adapter = PrintApiHono::new(&upstream.origin, TOKEN, timeouts.clone()).unwrap();
    let query = ListQuery::default();
    assert!(adapter.list_orders(&query).await.is_ok());

    let wrong = PrintApiHono::new(&upstream.origin, &"x".repeat(40), timeouts.clone()).unwrap();
    assert_eq!(unavailable(wrong.list_orders(&query).await), "credential");
    upstream.set_mode(1);
    assert_eq!(unavailable(adapter.list_orders(&query).await), "redirect");
    upstream.set_mode(2);
    assert_eq!(unavailable(adapter.list_orders(&query).await), "contract");
    assert_eq!(
        unavailable(adapter.get_order(&uuid::Uuid::new_v4().to_string()).await),
        "contract"
    );
    upstream.set_mode(0);
    upstream.set_delay_ms(1_000);
    assert_eq!(unavailable(adapter.list_orders(&query).await), "timeout");
    upstream.set_delay_ms(0);
    fake.set_unavailable(true);
    assert_eq!(
        unavailable(adapter.list_orders(&query).await),
        "upstream_error"
    );

    let closed = PrintApiHono::new("http://127.0.0.1:9", TOKEN, timeouts).unwrap();
    assert_eq!(unavailable(closed.list_orders(&query).await), "transport");
}

#[test]
fn adapter_configuration_is_validated_without_echoing_values() {
    assert_eq!(
        parse_origin("https://api.example.org").as_deref(),
        Some("https://api.example.org")
    );
    assert_eq!(
        parse_origin("http://127.0.0.1:3999").as_deref(),
        Some("http://127.0.0.1:3999")
    );
    for bad in [
        "https://api.example.org/",
        "https://api.example.org/api",
        "https://user:pw@api.example.org",
        "ftp://api.example.org",
        "https://api.example.org?x=1",
        "not a url",
    ] {
        assert_eq!(parse_origin(bad), None, "{bad}");
    }
    let secret = "s3cr3t-token-value-that-must-not-leak-0000";
    let error = PrintApiHono::new("https://x.org/path", secret, Timeouts::default())
        .err()
        .unwrap();
    assert!(!error.to_string().contains(secret));
    assert!(PrintApiHono::new("https://x.org", "short", Timeouts::default()).is_err());
    assert!(
        PrintApiHono::new(
            "https://x.org",
            &format!("{}\n", "a".repeat(40)),
            Timeouts::default()
        )
        .is_err()
    );
}
