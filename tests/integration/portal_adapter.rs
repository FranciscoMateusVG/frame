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
    crate::portal_api_conformance::seed(&fake, &crate::portal_api_conformance::snapshot("open"));
    let upstream = FakeHono::start(fake.clone()).await;
    let timeouts = Timeouts {
        json: Duration::from_millis(300),
        ..Timeouts::default()
    };
    let adapter = PrintApiHono::new(&upstream.origin, TOKEN, timeouts.clone()).unwrap();
    let query = ListQuery::default();
    assert!(adapter.list_batches(&query).await.is_ok());

    let wrong = PrintApiHono::new(&upstream.origin, &"x".repeat(40), timeouts.clone()).unwrap();
    assert_eq!(unavailable(wrong.list_batches(&query).await), "credential");
    upstream.set_mode(1);
    assert_eq!(unavailable(adapter.list_batches(&query).await), "redirect");
    upstream.set_mode(2);
    assert_eq!(unavailable(adapter.list_batches(&query).await), "contract");
    assert_eq!(
        unavailable(adapter.get_batch(&uuid::Uuid::new_v4().to_string()).await),
        "contract"
    );
    upstream.set_mode(0);
    upstream.set_delay_ms(1_000);
    assert_eq!(unavailable(adapter.list_batches(&query).await), "timeout");
    upstream.set_delay_ms(0);
    fake.set_unavailable(true);
    assert_eq!(
        unavailable(adapter.list_batches(&query).await),
        "upstream_error"
    );

    let closed = PrintApiHono::new("http://127.0.0.1:9", TOKEN, timeouts).unwrap();
    assert_eq!(unavailable(closed.list_batches(&query).await), "transport");
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

/// An upstream that answers every connection with exactly `response`.
pub(crate) async fn raw_upstream(response: Vec<u8>) -> String {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let response = response.clone();
            tokio::spawn(async move {
                let mut head = vec![0u8; 8192];
                let _ = socket.read(&mut head).await;
                let _ = socket.write_all(&response).await;
                let _ = socket.shutdown().await;
            });
        }
    });
    origin
}

pub(crate) fn file_response(headers: &str, body: &[u8]) -> Vec<u8> {
    let mut r = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\n\
         Content-Disposition: attachment; filename=\"a.pdf\"\r\nConnection: close\r\n{headers}\r\n"
    )
    .into_bytes();
    r.extend_from_slice(body);
    r
}

async fn collect(download: frame_portal_port::Download) -> Result<Vec<u8>, std::io::Error> {
    use futures_util::TryStreamExt;
    download
        .body
        .try_fold(Vec::new(), |mut acc, chunk| async move {
            acc.extend_from_slice(&chunk);
            Ok(acc)
        })
        .await
}

#[tokio::test]
async fn downloads_are_bounded_and_must_match_their_declared_length() {
    let order = uuid::Uuid::new_v4().to_string();
    let file = uuid::Uuid::new_v4().to_string();
    let adapter = |origin: &str| PrintApiHono::new(origin, TOKEN, Timeouts::default()).unwrap();

    // Exact length: streamed as is.
    let ok = raw_upstream(file_response("Content-Length: 9\r\n", b"%PDF-1.4\n")).await;
    let d = adapter(&ok)
        .batch_file(&order, &order, &file)
        .await
        .unwrap();
    assert_eq!(d.length, Some(9));
    assert_eq!(collect(d).await.unwrap(), b"%PDF-1.4\n");

    // No declared length (chunked): refused before streaming.
    let chunked = raw_upstream(file_response(
        "Transfer-Encoding: chunked\r\n",
        b"9\r\n%PDF-1.4\n\r\n0\r\n\r\n",
    ))
    .await;
    assert_eq!(
        unavailable(adapter(&chunked).batch_file(&order, &order, &file).await),
        "contract"
    );

    // Declared beyond the cap: refused before streaming.
    let huge = raw_upstream(file_response(
        &format!(
            "Content-Length: {}\r\n",
            frame_portal_hono::MAX_DOWNLOAD_BYTES + 1
        ),
        b"%PDF",
    ))
    .await;
    assert_eq!(
        unavailable(adapter(&huge).quote_file(&order, &file).await),
        "contract"
    );

    // Short body: the stream fails instead of ending as if complete.
    let short = raw_upstream(file_response("Content-Length: 1000\r\n", b"%PDF-1.4\n")).await;
    let d = adapter(&short)
        .batch_file(&order, &order, &file)
        .await
        .unwrap();
    assert!(
        collect(d).await.is_err(),
        "truncated body must not look complete"
    );

    // Longer than declared: never more than the declared bytes.
    let long = raw_upstream(file_response("Content-Length: 4\r\n", b"%PDF-1.4\n")).await;
    let d = adapter(&long)
        .batch_file(&order, &order, &file)
        .await
        .unwrap();
    assert_eq!(collect(d).await.unwrap(), b"%PDF");
}
