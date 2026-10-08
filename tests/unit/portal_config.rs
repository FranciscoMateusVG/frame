use frame_portal_web::Config;
use std::collections::HashMap;

fn env(extra: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let mut vars: HashMap<String, String> = [
        ("PRINT_PORTAL_PASSWORD", "senha-da-grafica-2026!"),
        (
            "INCLUIR_PRINT_SERVICE_TOKEN",
            "token-de-servico-0123456789abcdef0123",
        ),
        ("INCLUIR_PRINT_API_ORIGIN", "http://127.0.0.1:3999"),
        ("PRINT_PORTAL_ORIGIN", "http://127.0.0.1:4000"),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_owned(), v.to_owned()))
    .collect();
    for (k, v) in extra {
        vars.insert((*k).into(), (*v).into());
    }
    move |name| vars.get(name).cloned()
}

#[test]
fn rejects_an_11_character_password() {
    let password = "p".repeat(11);
    let error = Config::from_env(&env(&[("PRINT_PORTAL_PASSWORD", &password)])).unwrap_err();
    assert_eq!(
        error.to_string(),
        "PRINT_PORTAL_PASSWORD must have at least 12 characters"
    );
}

#[test]
fn accepts_a_12_character_password() {
    let password = "p".repeat(12);
    assert!(Config::from_env(&env(&[("PRINT_PORTAL_PASSWORD", &password)])).is_ok());
}

#[test]
fn session_ttl_overrides_can_only_shorten_the_spec_maxima() {
    let config = Config::from_env(&env(&[])).unwrap();
    assert_eq!(config.session.idle.num_seconds(), 1800);
    assert_eq!(config.session.absolute.num_seconds(), 28800);
    let short = Config::from_env(&env(&[
        ("PRINT_PORTAL_SESSION_IDLE_SECONDS", "5"),
        ("PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS", "12"),
    ]))
    .unwrap();
    assert_eq!(
        (
            short.session.idle.num_seconds(),
            short.session.absolute.num_seconds()
        ),
        (5, 12)
    );
    let edge = Config::from_env(&env(&[
        ("PRINT_PORTAL_SESSION_IDLE_SECONDS", "1800"),
        ("PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS", "28800"),
    ]));
    assert!(edge.is_ok());
    for (name, value) in [
        ("PRINT_PORTAL_SESSION_IDLE_SECONDS", "1801"),
        ("PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS", "28801"),
        ("PRINT_PORTAL_SESSION_IDLE_SECONDS", "604800"),
        ("PRINT_PORTAL_SESSION_IDLE_SECONDS", "0"),
        ("PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS", "-1"),
        ("PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS", "8h"),
    ] {
        let error = Config::from_env(&env(&[(name, value)])).unwrap_err();
        assert!(error.to_string().contains(name), "{name}={value}: {error}");
    }
}

#[test]
fn configuration_errors_name_the_variable_never_the_value() {
    for (vars, name) in [
        (vec![("PRINT_PORTAL_PASSWORD", "")], "PRINT_PORTAL_PASSWORD"),
        (
            vec![("PRINT_PORTAL_PASSWORD", "curta")],
            "PRINT_PORTAL_PASSWORD",
        ),
        (
            vec![("INCLUIR_PRINT_SERVICE_TOKEN", "senha-da-grafica-2026!")],
            "INCLUIR_PRINT_SERVICE_TOKEN",
        ),
        (
            vec![("INCLUIR_PRINT_API_ORIGIN", "http://x.org/api")],
            "INCLUIR_PRINT_API_ORIGIN",
        ),
        (
            vec![("PRINT_PORTAL_ORIGIN", "nao-e-url")],
            "PRINT_PORTAL_ORIGIN",
        ),
        (vec![("PRINT_PORTAL_BIND", "porta")], "PRINT_PORTAL_BIND"),
        (
            vec![("PRINT_PORTAL_TRUSTED_PROXIES", "10.0.0.1,x")],
            "PRINT_PORTAL_TRUSTED_PROXIES",
        ),
    ] {
        let error = Config::from_env(&env(&vars)).unwrap_err().to_string();
        assert!(error.contains(name), "{error}");
        for (_, value) in &vars {
            if !value.is_empty() {
                assert!(!error.contains(value), "{error} echoes {value}");
            }
        }
    }
    let config =
        Config::from_env(&env(&[("PRINT_PORTAL_TRUSTED_PROXIES", "10.0.0.1, ::1")])).unwrap();
    assert_eq!(config.trusted_proxies.len(), 2);
    assert!(!format!("{config:?}").contains("senha-da-grafica"));
}
