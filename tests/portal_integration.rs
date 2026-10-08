//! Print portal across real sockets: the HTTP adapter against a fake Hono,
//! and the browser-facing BFF end to end.
#[path = "integration/portal_adapter.rs"]
mod portal_adapter;
#[path = "helpers/portal_api_conformance.rs"]
mod portal_api_conformance;
#[path = "helpers/portal_browser.rs"]
mod portal_browser;
#[path = "helpers/portal_fake_hono.rs"]
mod portal_fake_hono;
#[path = "integration/portal_web.rs"]
mod portal_web;
