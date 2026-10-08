//! Login attempt limiter (spec §5): 5 invalid attempts / 15 min per client
//! address plus 100 / 15 min per instance. Only failures are counted; a
//! limited client is refused before its password is even compared.
use chrono::{DateTime, TimeDelta, Utc};
use std::{
    collections::{HashMap, VecDeque},
    net::IpAddr,
    sync::Mutex,
};

#[derive(Clone, Debug)]
pub struct LimiterPolicy {
    pub window: TimeDelta,
    pub per_client: usize,
    pub per_instance: usize,
    /// Hard cap on tracked addresses (memory DoS bound).
    pub max_clients: usize,
}
impl Default for LimiterPolicy {
    fn default() -> Self {
        Self {
            window: TimeDelta::minutes(15),
            per_client: 5,
            per_instance: 100,
            max_clients: 10_000,
        }
    }
}

#[derive(Default)]
struct Inner {
    clients: HashMap<IpAddr, VecDeque<DateTime<Utc>>>,
    instance: VecDeque<DateTime<Utc>>,
}

pub struct LoginLimiter {
    policy: LimiterPolicy,
    inner: Mutex<Inner>,
}

fn prune(q: &mut VecDeque<DateTime<Utc>>, since: DateTime<Utc>) {
    while q.front().is_some_and(|t| *t <= since) {
        q.pop_front();
    }
}

impl LoginLimiter {
    pub fn new(policy: LimiterPolicy) -> Self {
        Self {
            policy,
            inner: Mutex::default(),
        }
    }
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// `Err(seconds)` while the client or the instance is over its budget.
    pub fn check(&self, client: IpAddr, now: DateTime<Utc>) -> Result<(), u64> {
        let since = now - self.policy.window;
        let mut inner = self.lock();
        prune(&mut inner.instance, since);
        let mut wait: Option<DateTime<Utc>> = None;
        if inner.instance.len() >= self.policy.per_instance {
            wait = Some(inner.instance[inner.instance.len() - self.policy.per_instance]);
        }
        if let Some(q) = inner.clients.get_mut(&client) {
            prune(q, since);
            if q.len() >= self.policy.per_client {
                let oldest = q[q.len() - self.policy.per_client];
                wait = Some(wait.map_or(oldest, |w| w.max(oldest)));
            }
        }
        match wait {
            None => Ok(()),
            Some(oldest) => {
                let seconds = (oldest + self.policy.window - now).num_seconds().max(0) as u64;
                Err(seconds.max(1))
            }
        }
    }

    pub fn record_failure(&self, client: IpAddr, now: DateTime<Utc>) {
        let since = now - self.policy.window;
        let mut inner = self.lock();
        inner.instance.push_back(now);
        if !inner.clients.contains_key(&client) && inner.clients.len() >= self.policy.max_clients {
            inner.clients.retain(|_, q| {
                prune(q, since);
                !q.is_empty()
            });
            if inner.clients.len() >= self.policy.max_clients {
                // Still saturated: the instance budget alone applies.
                return;
            }
        }
        inner.clients.entry(client).or_default().push_back(now);
    }

    pub fn tracked_clients(&self) -> usize {
        self.lock().clients.len()
    }
}
