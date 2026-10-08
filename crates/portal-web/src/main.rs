//! `print-portal`: production entrypoint. Configuration comes only from the
//! environment and is validated before binding; a missing or invalid value
//! exits non-zero naming the variable (never its value). OTel providers are
//! the deployer's concern: without one, spans and logs are no-ops.
use frame_observability::{ConsoleLogger, Observability};
use frame_portal_web::{Config, Server, compose};
use std::{process::ExitCode, sync::Arc};

#[tokio::main]
async fn main() -> ExitCode {
    // Panic payloads may carry request data: report only that one happened.
    std::panic::set_hook(frame_portal_web::panic_hook(Box::new(|line| {
        eprint!("{line}");
    })));
    let config = match Config::from_env(&|name| std::env::var(name).ok()) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("print-portal: configuration error: {error}");
            return ExitCode::from(2);
        }
    };
    let observability = Observability {
        logger: Arc::new(ConsoleLogger),
        ..Observability::default()
    };
    let router = match compose(&config, observability) {
        Ok(router) => router,
        Err(error) => {
            eprintln!("print-portal: configuration error: {error}");
            return ExitCode::from(2);
        }
    };
    let listener = match tokio::net::TcpListener::bind(config.bind).await {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("print-portal: cannot bind {}: {error}", config.bind);
            return ExitCode::from(1);
        }
    };
    let server = match Server::start(listener, router).await {
        Ok(server) => server,
        Err(error) => {
            eprintln!("print-portal: cannot start: {error}");
            return ExitCode::from(1);
        }
    };
    println!("print-portal listening on {}", server.base_url);
    tokio::select! {
        result = server.wait() => match result {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("print-portal: server error: {error}");
                ExitCode::from(1)
            }
        },
        _ = terminated() => ExitCode::SUCCESS,
    }
}

/// SIGINT or (on Unix) SIGTERM, as sent by container runtimes.
async fn terminated() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        match signal(SignalKind::terminate()) {
            Ok(mut term) => {
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => {}
                    _ = term.recv() => {}
                }
            }
            Err(_) => {
                let _ = tokio::signal::ctrl_c().await;
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
