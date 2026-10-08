//! Server-side session registry (spec §5): opaque random ids, 8 h absolute /
//! 30 min idle, rotation at login, immediate revocation, nothing survives a
//! restart. Pre-sessions carry the login CSRF binding. Both maps are bounded.
use chrono::{DateTime, TimeDelta, Utc};
use std::{collections::HashMap, sync::Mutex};
use subtle::ConstantTimeEq;

#[derive(Clone, Debug)]
pub struct SessionPolicy {
    pub idle: TimeDelta,
    pub absolute: TimeDelta,
    pub presession_ttl: TimeDelta,
    pub max_sessions: usize,
    pub max_presessions: usize,
}
impl Default for SessionPolicy {
    fn default() -> Self {
        Self {
            idle: TimeDelta::minutes(30),
            absolute: TimeDelta::hours(8),
            presession_ttl: TimeDelta::hours(2),
            max_sessions: 1_000,
            max_presessions: 10_000,
        }
    }
}

/// What a request learns about its (pre-)session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionView {
    pub id: String,
    pub csrf: String,
    pub expires_at: DateTime<Utc>,
}

struct Entry {
    csrf: String,
    created: DateTime<Utc>,
    last_seen: DateTime<Utc>,
}

#[derive(Default)]
struct Inner {
    sessions: HashMap<String, Entry>,
    presessions: HashMap<String, Entry>,
}

pub type IdGenerator = dyn Fn() -> String + Send + Sync;

pub struct SessionRegistry {
    policy: SessionPolicy,
    inner: Mutex<Inner>,
}

/// Constant-time token comparison (length is not secret).
pub fn tokens_match(a: &str, b: &str) -> bool {
    a.len() == b.len() && bool::from(a.as_bytes().ct_eq(b.as_bytes()))
}

impl SessionRegistry {
    pub fn new(policy: SessionPolicy) -> Self {
        Self {
            policy,
            inner: Mutex::default(),
        }
    }
    pub fn policy(&self) -> &SessionPolicy {
        &self.policy
    }
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
    fn session_expiry(&self, e: &Entry) -> DateTime<Utc> {
        (e.last_seen + self.policy.idle).min(e.created + self.policy.absolute)
    }
    fn presession_expiry(&self, e: &Entry) -> DateTime<Utc> {
        e.created + self.policy.presession_ttl
    }

    /// Live authenticated session; touching it extends the idle window.
    pub fn session(&self, id: &str, now: DateTime<Utc>) -> Option<SessionView> {
        let mut inner = self.lock();
        let entry = inner.sessions.get(id)?;
        if self.session_expiry(entry) <= now {
            inner.sessions.remove(id);
            return None;
        }
        let entry = inner.sessions.get_mut(id).expect("present");
        entry.last_seen = now;
        let expires_at = (now + self.policy.idle).min(entry.created + self.policy.absolute);
        Some(SessionView {
            id: id.to_owned(),
            csrf: entry.csrf.clone(),
            expires_at,
        })
    }

    /// The live pre-session `id`, or a new one when absent/expired.
    /// Returns the view and whether a cookie must be (re)issued.
    pub fn presession(
        &self,
        id: Option<&str>,
        now: DateTime<Utc>,
        new_id: &IdGenerator,
    ) -> (SessionView, bool) {
        let mut inner = self.lock();
        if let Some(id) = id
            && let Some(entry) = inner.presessions.get(id)
        {
            let expires_at = self.presession_expiry(entry);
            if expires_at > now {
                return (
                    SessionView {
                        id: id.to_owned(),
                        csrf: entry.csrf.clone(),
                        expires_at,
                    },
                    false,
                );
            }
            inner.presessions.remove(id);
        }
        if inner.presessions.len() >= self.policy.max_presessions {
            let ttl = self.policy.presession_ttl;
            inner.presessions.retain(|_, e| e.created + ttl > now);
            evict_oldest(&mut inner.presessions, self.policy.max_presessions);
        }
        let entry = Entry {
            csrf: new_id(),
            created: now,
            last_seen: now,
        };
        let view = SessionView {
            id: new_id(),
            csrf: entry.csrf.clone(),
            expires_at: self.presession_expiry(&entry),
        };
        inner.presessions.insert(view.id.clone(), entry);
        (view, true)
    }

    /// Pre-session exists, is live, and `csrf` is its token.
    pub fn presession_accepts(&self, id: &str, csrf: &str, now: DateTime<Utc>) -> bool {
        let inner = self.lock();
        inner
            .presessions
            .get(id)
            .is_some_and(|e| self.presession_expiry(e) > now && tokens_match(&e.csrf, csrf))
    }

    /// Login: a brand-new id and CSRF token; the pre-session and any prior
    /// session presented by the browser are revoked (rotation).
    pub fn open(
        &self,
        now: DateTime<Utc>,
        new_id: &IdGenerator,
        presession: Option<&str>,
        previous: Option<&str>,
    ) -> SessionView {
        let mut inner = self.lock();
        if let Some(id) = presession {
            inner.presessions.remove(id);
        }
        if let Some(id) = previous {
            inner.sessions.remove(id);
        }
        if inner.sessions.len() >= self.policy.max_sessions {
            let (idle, absolute) = (self.policy.idle, self.policy.absolute);
            inner
                .sessions
                .retain(|_, e| (e.last_seen + idle).min(e.created + absolute) > now);
            evict_oldest(&mut inner.sessions, self.policy.max_sessions);
        }
        let entry = Entry {
            csrf: new_id(),
            created: now,
            last_seen: now,
        };
        let view = SessionView {
            id: new_id(),
            csrf: entry.csrf.clone(),
            expires_at: self.session_expiry(&entry),
        };
        inner.sessions.insert(view.id.clone(), entry);
        view
    }

    /// Logout: the id stops working immediately. Unknown ids are a no-op.
    pub fn revoke(&self, id: &str) -> bool {
        self.lock().sessions.remove(id).is_some()
    }

    pub fn counts(&self) -> (usize, usize) {
        let inner = self.lock();
        (inner.sessions.len(), inner.presessions.len())
    }
}

fn evict_oldest(map: &mut HashMap<String, Entry>, cap: usize) {
    while map.len() >= cap {
        let Some(oldest) = map
            .iter()
            .min_by_key(|(_, e)| e.last_seen)
            .map(|(k, _)| k.clone())
        else {
            return;
        };
        map.remove(&oldest);
    }
}
