//! Print portal: pure domain, session/limiter logic, and the shared
//! `PrintApi` contract against the in-memory upstream fake.
#[path = "helpers/portal_api_conformance.rs"]
mod portal_api_conformance;
#[path = "unit/portal_config.rs"]
mod portal_config;
#[path = "unit/portal_domain.rs"]
mod portal_domain;
#[path = "unit/portal_property.rs"]
mod portal_property;
#[path = "unit/portal_session.rs"]
mod portal_session;

use portal_api_conformance::{SPANS, TestClock, run};

#[tokio::test]
async fn memory_fake_satisfies_the_print_api_contract_with_equivalent_spans() {
    let obs = frame_testing::TestObservability::new();
    let clock = TestClock::at(2026, 9, 10);
    let fake = frame_portal_memory::PrintApiMemory::new(clock.as_fn());
    run(&fake, &fake, &clock).await;
    let spans = obs.get_spans();
    for name in SPANS {
        let span = spans
            .iter()
            .find(|s| s.name == *name)
            .unwrap_or_else(|| panic!("missing span {name}"));
        assert!(
            span.attributes
                .iter()
                .any(|kv| kv.key.as_str() == "print_api.system"
                    && kv.value.as_str() == frame_portal_memory::SYSTEM)
        );
    }
}

#[tokio::test]
async fn memory_fake_outage_is_unavailable_not_a_contract_error() {
    use frame_portal_port::{ApiError, ListQuery, PrintApi};
    let fake = frame_portal_memory::PrintApiMemory::default();
    fake.set_unavailable(true);
    assert!(matches!(
        fake.list_batches(&ListQuery::default()).await,
        Err(ApiError::Unavailable { .. })
    ));
    fake.set_unavailable(false);
    assert!(fake.list_batches(&ListQuery::default()).await.is_ok());
}
