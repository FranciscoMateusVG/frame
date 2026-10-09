//! Port to the Incluir print-portal service API (`/api/print-portal/v2`).
//! Implementations: `frame-portal-hono` (real HTTP) and `frame-portal-memory`
//! (in-memory fake with the same contract). No observability dependency.
use async_trait::async_trait;
use bytes::Bytes;
use frame_portal_domain::{Batch, BatchList, BatchStatus, Close, Competence};
use futures_util::stream::BoxStream;
use std::fmt;

/// Error codes the upstream contract defines; the BFF passes them through.
pub mod codes {
    pub const INVALID_REQUEST: &str = "INVALID_REQUEST";
    pub const INVALID_CURSOR: &str = "INVALID_CURSOR";
    pub const INVALID_COMPETENCE: &str = "INVALID_COMPETENCE";
    pub const NOT_FOUND: &str = "NOT_FOUND";
    pub const METHOD_NOT_ALLOWED: &str = "METHOD_NOT_ALLOWED";
    pub const INVALID_STATE: &str = "INVALID_STATE";
    pub const BATCH_NOT_ACTIVE: &str = "BATCH_NOT_ACTIVE";
    pub const BATCH_WORKFLOW_REQUIRED: &str = "BATCH_WORKFLOW_REQUIRED";
    pub const EMPTY_BATCH: &str = "EMPTY_BATCH";
    pub const IDEMPOTENCY_CONFLICT: &str = "IDEMPOTENCY_CONFLICT";
    pub const OPERATION_IN_PROGRESS: &str = "OPERATION_IN_PROGRESS";
    pub const PERIOD_OPEN: &str = "PERIOD_OPEN";
    pub const EMPTY_CLOSE: &str = "EMPTY_CLOSE";
    pub const VERSION_MISMATCH: &str = "VERSION_MISMATCH";
    pub const FILE_TOO_LARGE: &str = "FILE_TOO_LARGE";
    pub const UNSUPPORTED_MEDIA_TYPE: &str = "UNSUPPORTED_MEDIA_TYPE";
    pub const PRECONDITION_REQUIRED: &str = "PRECONDITION_REQUIRED";
    pub const RATE_LIMITED: &str = "RATE_LIMITED";
    pub const UPSTREAM_UNAVAILABLE: &str = "UPSTREAM_UNAVAILABLE";
}

/// Upload cap for quotes and NFs (spec §4.3): 5 MiB per file.
pub const DOCUMENT_MAX_BYTES: usize = 5 * 1024 * 1024;

#[derive(Debug)]
pub enum ApiError {
    /// A contract error answered by the upstream (4xx), safe to relay.
    Rejected {
        status: u16,
        code: String,
        message: String,
        retry_after: Option<u64>,
    },
    /// Timeout, transport failure, bad credential/config upstream, 5xx,
    /// redirect or a body that breaks the contract. Never a reason to ask
    /// the person for the password again.
    Unavailable { reason: &'static str },
}
impl ApiError {
    pub fn rejected(status: u16, code: &str, message: &str) -> Self {
        Self::Rejected {
            status,
            code: code.into(),
            message: message.into(),
            retry_after: None,
        }
    }
    pub fn code(&self) -> &str {
        match self {
            Self::Rejected { code, .. } => code,
            Self::Unavailable { .. } => codes::UPSTREAM_UNAVAILABLE,
        }
    }
}
impl fmt::Display for ApiError {
    // Codes and fixed reasons only: never request content.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Rejected { status, code, .. } => write!(f, "upstream {status} {code}"),
            Self::Unavailable { reason } => write!(f, "upstream unavailable: {reason}"),
        }
    }
}
impl std::error::Error for ApiError {}

pub type ApiResult<T> = Result<T, ApiError>;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ListQuery {
    pub status: Option<BatchStatus>,
    pub limit: Option<u32>,
    pub cursor: Option<String>,
}

/// `If-Match` + `Idempotency-Key`, forwarded verbatim (the upstream decides).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Preconditions {
    pub if_match: Option<String>,
    pub idempotency_key: Option<String>,
}

/// A resource plus its strong ETag.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tagged<T> {
    pub body: T,
    pub etag: String,
}

/// Result of a conditional, idempotent command.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Command<T> {
    pub status: u16,
    pub body: T,
    pub etag: String,
    pub replayed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Upload {
    pub filename: String,
    pub bytes: Bytes,
}

pub struct Download {
    pub mime: String,
    pub length: Option<u64>,
    pub filename: String,
    pub body: BoxStream<'static, Result<Bytes, std::io::Error>>,
}
impl fmt::Debug for Download {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Download")
            .field("mime", &self.mime)
            .field("length", &self.length)
            .finish_non_exhaustive()
    }
}

#[async_trait]
pub trait PrintApi: Send + Sync {
    /// All batches (history included), `createdAt ASC, id ASC`.
    async fn list_batches(&self, query: &ListQuery) -> ApiResult<BatchList>;
    /// The open batch, or `None` (also while a collected…printed one is active).
    async fn open_batch(&self) -> ApiResult<Option<Tagged<Batch>>>;
    async fn get_batch(&self, batch_id: &str) -> ApiResult<Tagged<Batch>>;
    async fn batch_file(
        &self,
        batch_id: &str,
        order_id: &str,
        file_id: &str,
    ) -> ApiResult<Download>;
    async fn collect(&self, batch_id: &str, pre: &Preconditions) -> ApiResult<Command<Batch>>;
    async fn submit_quote(
        &self,
        batch_id: &str,
        amount_cents: i64,
        file: Upload,
        pre: &Preconditions,
    ) -> ApiResult<Command<Batch>>;
    async fn quote_file(&self, batch_id: &str, quote_id: &str) -> ApiResult<Download>;
    async fn mark_printed(
        &self,
        batch_id: &str,
        quote_id: &str,
        pre: &Preconditions,
    ) -> ApiResult<Command<Batch>>;
    async fn get_close(&self, competence: Competence) -> ApiResult<Tagged<Close>>;
    async fn submit_invoice(
        &self,
        competence: Competence,
        declared_total_cents: i64,
        file: Upload,
        pre: &Preconditions,
    ) -> ApiResult<Command<Close>>;
    async fn invoice_file(&self, competence: Competence) -> ApiResult<Download>;
}
