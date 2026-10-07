//! Example support, NOT part of the production SDK.
pub mod http;
#[path = "../../tests/helpers/test_db.rs"]
pub mod test_db;

pub fn clock() -> frame::Timestamp {
    let now: frame::Timestamp = std::time::SystemTime::now().into();
    chrono::DateTime::from_timestamp_millis(now.timestamp_millis()).unwrap()
}
