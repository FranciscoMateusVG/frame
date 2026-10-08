//! Process configuration from the environment (spec §5). Missing or invalid
//! values stop startup; errors name the variable, never its value. There
//! are no literal fallbacks for secrets or origins.
use chrono::TimeDelta;
use frame_portal_hono::parse_origin;
use frame_portal_use_cases::SessionPolicy;
use std::{fmt, net::IpAddr, net::SocketAddr};

pub struct Config {
    pub password: String,
    pub service_token: String,
    pub upstream_origin: String,
    pub portal_origin: String,
    pub bind: SocketAddr,
    pub session: SessionPolicy,
    pub trusted_proxies: Vec<IpAddr>,
}

impl fmt::Debug for Config {
    // Secrets are never formatted.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("upstream_origin", &self.upstream_origin)
            .field("portal_origin", &self.portal_origin)
            .field("bind", &self.bind)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct ConfigError(pub String);
impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for ConfigError {}

fn fail<T>(message: &str) -> Result<T, ConfigError> {
    Err(ConfigError(message.into()))
}

/// Test-only TTL overrides may shorten the spec values (§5: 30 min idle,
/// 8 h absolute), never lengthen them.
fn seconds(
    env: &dyn Fn(&str) -> Option<String>,
    name: &str,
    max: TimeDelta,
) -> Result<TimeDelta, ConfigError> {
    match env(name) {
        None => Ok(max),
        Some(raw) => match raw.parse::<i64>() {
            Ok(n) if (1..=max.num_seconds()).contains(&n) => Ok(TimeDelta::seconds(n)),
            _ => fail(&format!(
                "{name} must be between 1 and {} seconds",
                max.num_seconds()
            )),
        },
    }
}

impl Config {
    pub fn from_env(env: &dyn Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let required = |name: &str| {
            env(name)
                .filter(|v| !v.is_empty())
                .ok_or_else(|| ConfigError(format!("{name} is required")))
        };
        let password = required("PRINT_PORTAL_PASSWORD")?;
        if password.chars().count() < 12 {
            return fail("PRINT_PORTAL_PASSWORD must have at least 12 characters");
        }
        let service_token = required("INCLUIR_PRINT_SERVICE_TOKEN")?;
        if service_token == password {
            return fail("INCLUIR_PRINT_SERVICE_TOKEN must differ from PRINT_PORTAL_PASSWORD");
        }
        let upstream_origin =
            parse_origin(&required("INCLUIR_PRINT_API_ORIGIN")?).ok_or_else(|| {
                ConfigError("INCLUIR_PRINT_API_ORIGIN must be an http(s) origin".into())
            })?;
        let portal_origin = parse_origin(&required("PRINT_PORTAL_ORIGIN")?)
            .ok_or_else(|| ConfigError("PRINT_PORTAL_ORIGIN must be an http(s) origin".into()))?;
        let bind = env("PRINT_PORTAL_BIND")
            .unwrap_or_else(|| "127.0.0.1:4000".into())
            .parse()
            .map_err(|_| ConfigError("PRINT_PORTAL_BIND must be host:port".into()))?;
        let defaults = SessionPolicy::default();
        let idle = seconds(env, "PRINT_PORTAL_SESSION_IDLE_SECONDS", defaults.idle)?;
        let absolute = seconds(
            env,
            "PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS",
            defaults.absolute,
        )?;
        let trusted_proxies = match env("PRINT_PORTAL_TRUSTED_PROXIES") {
            None => vec![],
            Some(raw) => raw
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(|s| s.parse::<IpAddr>())
                .collect::<Result<_, _>>()
                .map_err(|_| {
                    ConfigError("PRINT_PORTAL_TRUSTED_PROXIES must be comma-separated IPs".into())
                })?,
        };
        Ok(Self {
            password,
            service_token,
            upstream_origin,
            portal_origin,
            bind,
            session: SessionPolicy {
                idle,
                absolute,
                ..defaults
            },
            trusted_proxies,
        })
    }
}
