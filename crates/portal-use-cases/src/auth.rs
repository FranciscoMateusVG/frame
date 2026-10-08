//! Shared-password login and logout (spec §4.5, §5). The password identifies
//! the print shop, not a person; nothing here ever logs or records it.
use crate::{LoginLimiter, SessionRegistry, SessionView, session::IdGenerator};
use chrono::{DateTime, Utc};
use frame_observability::{LogAttributes, Observability, in_span};
use opentelemetry::{Context, KeyValue, trace::TraceContextExt};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fmt, net::IpAddr};
use subtle::ConstantTimeEq;

/// Holds only the SHA-256 digest of the configured password; comparison is
/// digest-to-digest in constant time.
pub struct PasswordVerifier {
    digest: [u8; 32],
}
impl PasswordVerifier {
    pub fn new(password: &str) -> Self {
        Self {
            digest: Sha256::digest(password.as_bytes()).into(),
        }
    }
    pub fn verify(&self, candidate: &str) -> bool {
        let digest: [u8; 32] = Sha256::digest(candidate.as_bytes()).into();
        bool::from(digest.ct_eq(&self.digest))
    }
}

pub type Clock = dyn Fn() -> DateTime<Utc> + Send + Sync;

pub struct AuthDeps<'a> {
    pub sessions: &'a SessionRegistry,
    pub limiter: &'a LoginLimiter,
    pub password: &'a PasswordVerifier,
    pub clock: &'a Clock,
    pub new_id: &'a IdGenerator,
    pub observability: &'a Observability,
}

pub struct LoginInput<'a> {
    pub password: &'a str,
    pub client: IpAddr,
    pub presession_id: Option<&'a str>,
    pub csrf_token: Option<&'a str>,
    pub previous_session: Option<&'a str>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum LoginError {
    CsrfFailed,
    RateLimited { retry_after: u64 },
    InvalidCredentials,
}
impl LoginError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::CsrfFailed => "CSRF_FAILED",
            Self::RateLimited { .. } => "RATE_LIMITED",
            Self::InvalidCredentials => "INVALID_CREDENTIALS",
        }
    }
}
impl fmt::Display for LoginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.code())
    }
}
impl std::error::Error for LoginError {}

fn attrs(pairs: &[(&str, Value)]) -> LogAttributes {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), v.clone()))
        .collect()
}

/// CSRF binding of the pre-session → limiter → password → rotated session.
pub async fn login(deps: AuthDeps<'_>, input: LoginInput<'_>) -> Result<SessionView, LoginError> {
    in_span(&deps.observability.tracer, "login", vec![], async {
        let now = (deps.clock)();
        let logger = &deps.observability.logger;
        let bound = match (input.presession_id, input.csrf_token) {
            (Some(id), Some(token)) => deps.sessions.presession_accepts(id, token, now),
            _ => false,
        };
        if !bound {
            logger.warn("portal.login.csrf_failed", None);
            return Err(LoginError::CsrfFailed);
        }
        if let Err(retry_after) = deps.limiter.check(input.client, now) {
            Context::current()
                .span()
                .set_attribute(KeyValue::new("portal.login.outcome", "rate_limited"));
            logger.warn(
                "portal.login.rate_limited",
                Some(&attrs(&[("retryAfterSeconds", retry_after.into())])),
            );
            return Err(LoginError::RateLimited { retry_after });
        }
        if !deps.password.verify(input.password) {
            deps.limiter.record_failure(input.client, now);
            Context::current()
                .span()
                .set_attribute(KeyValue::new("portal.login.outcome", "invalid"));
            logger.warn("portal.login.failed", None);
            return Err(LoginError::InvalidCredentials);
        }
        let session = deps.sessions.open(
            now,
            deps.new_id,
            input.presession_id,
            input.previous_session,
        );
        Context::current()
            .span()
            .set_attribute(KeyValue::new("portal.login.outcome", "succeeded"));
        logger.info("portal.login.succeeded", None);
        Ok(session)
    })
    .await
}

pub struct LogoutDeps<'a> {
    pub sessions: &'a SessionRegistry,
    pub observability: &'a Observability,
}

/// Revokes the session immediately; repeating it reveals nothing.
pub async fn logout(deps: LogoutDeps<'_>, session_id: Option<&str>) -> Result<(), LoginError> {
    in_span(&deps.observability.tracer, "logout", vec![], async {
        if session_id.is_some_and(|id| deps.sessions.revoke(id)) {
            deps.observability
                .logger
                .info("portal.session.revoked", None);
        }
        Ok(())
    })
    .await
}
