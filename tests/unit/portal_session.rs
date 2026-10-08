use chrono::{TimeDelta, TimeZone, Utc};
use frame_portal_use_cases::*;
use std::{
    net::IpAddr,
    sync::atomic::{AtomicU64, Ordering},
};

fn ids() -> impl Fn() -> String + Send + Sync {
    let n = AtomicU64::new(0);
    move || format!("{:064x}", n.fetch_add(1, Ordering::SeqCst))
}

fn t0() -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 8, 12, 0, 0).unwrap()
}

#[test]
fn sessions_expire_on_idle_and_absolute_deadlines_and_rotate_at_login() {
    let ids = ids();
    let registry = SessionRegistry::new(SessionPolicy::default());
    let (pre, created) = registry.presession(None, t0(), &ids);
    assert!(created);
    assert!(registry.presession_accepts(&pre.id, &pre.csrf, t0()));
    assert!(!registry.presession_accepts(&pre.id, "wrong", t0()));
    let (same, created) = registry.presession(Some(&pre.id), t0(), &ids);
    assert!(!created);
    assert_eq!(same, pre);

    let session = registry.open(t0(), &ids, Some(&pre.id), None);
    assert_ne!(session.id, pre.id, "login never reuses the pre-session id");
    assert_ne!(session.csrf, pre.csrf, "CSRF binding changes with login");
    assert!(
        !registry.presession_accepts(&pre.id, &pre.csrf, t0()),
        "pre-session consumed"
    );
    assert_eq!(session.expires_at, t0() + TimeDelta::minutes(30));

    // Activity slides the idle window, up to the absolute 8 h.
    let mut now = t0();
    for _ in 0..16 {
        now += TimeDelta::minutes(29);
        assert!(registry.session(&session.id, now).is_some());
    }
    now += TimeDelta::minutes(29); // 16 × 29 min = 7h44; +29 min > 8h
    assert!(
        registry.session(&session.id, now).is_none(),
        "absolute deadline"
    );

    let idle = registry.open(t0(), &ids, None, None);
    assert!(
        registry
            .session(&idle.id, t0() + TimeDelta::minutes(30))
            .is_none(),
        "idle deadline"
    );

    let rotated = registry.open(t0(), &ids, None, None);
    let next = registry.open(t0(), &ids, None, Some(&rotated.id));
    assert!(
        registry.session(&rotated.id, t0()).is_none(),
        "previous session revoked at login"
    );
    assert!(registry.revoke(&next.id));
    assert!(registry.session(&next.id, t0()).is_none());
    assert!(!registry.revoke(&next.id), "repeat revoke is a no-op");
}

#[test]
fn registries_are_bounded() {
    let ids = ids();
    let registry = SessionRegistry::new(SessionPolicy {
        max_presessions: 10,
        max_sessions: 3,
        ..SessionPolicy::default()
    });
    for i in 0..100 {
        registry.presession(None, t0() + TimeDelta::seconds(i), &ids);
    }
    for i in 0..10 {
        registry.open(t0() + TimeDelta::seconds(i), &ids, None, None);
    }
    let (sessions, presessions) = registry.counts();
    assert!(
        sessions <= 3 && presessions <= 10,
        "{sessions} {presessions}"
    );
}

#[test]
fn limiter_counts_failures_per_client_and_per_instance() {
    let limiter = LoginLimiter::new(LimiterPolicy::default());
    let a: IpAddr = "203.0.113.7".parse().unwrap();
    let b: IpAddr = "203.0.113.8".parse().unwrap();
    for i in 0..5 {
        assert!(limiter.check(a, t0()).is_ok(), "attempt {i}");
        limiter.record_failure(a, t0() + TimeDelta::seconds(i));
    }
    let wait = limiter.check(a, t0() + TimeDelta::seconds(10)).unwrap_err();
    assert_eq!(wait, 15 * 60 - 10);
    assert!(
        limiter.check(b, t0()).is_ok(),
        "other clients are unaffected"
    );
    assert!(
        limiter.check(a, t0() + TimeDelta::minutes(15)).is_ok(),
        "window slides"
    );

    let instance = LoginLimiter::new(LimiterPolicy::default());
    for i in 0..100u32 {
        let ip = IpAddr::from([198, 51, (i / 250) as u8, (i % 250) as u8]);
        instance.record_failure(ip, t0());
    }
    let fresh: IpAddr = "192.0.2.1".parse().unwrap();
    assert!(
        instance.check(fresh, t0()).is_err(),
        "instance budget applies to everyone"
    );

    let bounded = LoginLimiter::new(LimiterPolicy {
        max_clients: 10,
        per_instance: 10_000,
        ..LimiterPolicy::default()
    });
    for i in 0..1000u32 {
        bounded.record_failure(IpAddr::from(i.to_be_bytes()), t0());
    }
    assert!(bounded.tracked_clients() <= 10);
}

#[test]
fn password_verification_is_by_digest_and_tokens_compare_exactly() {
    let verifier = PasswordVerifier::new("senha-de-teste-com-16");
    assert!(verifier.verify("senha-de-teste-com-16"));
    assert!(!verifier.verify("senha-de-teste-com-1"));
    assert!(!verifier.verify(""));
    assert!(tokens_match("abc", "abc"));
    assert!(!tokens_match("abc", "abd"));
    assert!(!tokens_match("abc", "abcd"));
}
