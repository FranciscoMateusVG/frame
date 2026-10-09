//! Supplier projection of the Incluir print-portal service API v2 (batches).
//! Shapes mirror `print-portal-v2.schema.json` exactly: unknown fields are
//! rejected and every constraint is re-checked by [`Validate`].
use crate::{MAX_CENTS, is_sha256_hex, is_uuid, utf16_len};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};

/// JavaScript's `Number.MAX_SAFE_INTEGER`, the schema's integer ceiling.
pub const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

/// A UTC RFC 3339 instant (`…Z`) kept verbatim, so a pass-through never
/// changes the upstream's precision.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct Instant(String);
impl Instant {
    pub fn parse(raw: &str) -> Option<Self> {
        (raw.ends_with('Z') && DateTime::parse_from_rfc3339(raw).is_ok())
            .then(|| Self(raw.to_owned()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
    pub fn to_utc(&self) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(&self.0)
            .expect("validated on construction")
            .with_timezone(&Utc)
    }
}
impl From<DateTime<Utc>> for Instant {
    fn from(at: DateTime<Utc>) -> Self {
        Self(at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
    }
}
impl<'de> Deserialize<'de> for Instant {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(d)?;
        Self::parse(&raw).ok_or_else(|| serde::de::Error::custom("invalid UTC instant"))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QuoteDecision {
    Pending,
    Approved,
    Rejected,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Currency {
    #[serde(rename = "BRL")]
    Brl,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FileRef {
    pub id: String,
    pub name: String,
    pub mime: String,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PrintJob {
    pub id: String,
    pub title: String,
    pub copies: u32,
    pub instructions: String,
    pub file: FileRef,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BatchStatus {
    Open,
    FilesCollected,
    QuotePending,
    QuoteRejected,
    QuoteApproved,
    Printed,
    Received,
    Cancelled,
}
impl BatchStatus {
    pub const ALL: [Self; 8] = [
        Self::Open,
        Self::FilesCollected,
        Self::QuotePending,
        Self::QuoteRejected,
        Self::QuoteApproved,
        Self::Printed,
        Self::Received,
        Self::Cancelled,
    ];
    /// The supplier's current batch is one of these (at most one at a time).
    pub const CURRENT: [Self; 6] = [
        Self::Open,
        Self::FilesCollected,
        Self::QuotePending,
        Self::QuoteRejected,
        Self::QuoteApproved,
        Self::Printed,
    ];
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::FilesCollected => "files_collected",
            Self::QuotePending => "quote_pending",
            Self::QuoteRejected => "quote_rejected",
            Self::QuoteApproved => "quote_approved",
            Self::Printed => "printed",
            Self::Received => "received",
            Self::Cancelled => "cancelled",
        }
    }
    pub fn parse(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.as_str() == raw)
    }
    pub fn is_current(self) -> bool {
        Self::CURRENT.contains(&self)
    }
    /// Label shown to the print shop.
    pub fn label(self) -> &'static str {
        match self {
            Self::Open => "Pronto",
            Self::FilesCollected => "Arquivos retirados",
            Self::QuotePending => "Orçamento enviado",
            Self::QuoteRejected => "Orçamento rejeitado",
            Self::QuoteApproved => "Orçamento aprovado",
            Self::Printed => "Impresso",
            Self::Received => "Recebido",
            Self::Cancelled => "Cancelado",
        }
    }
    /// Steps of the progress bar reached so far (`0..=4`); `None` once the
    /// batch left the supplier's workflow (received/cancelled).
    pub fn progress(self) -> Option<usize> {
        match self {
            Self::Open => Some(0),
            Self::FilesCollected => Some(1),
            Self::QuotePending | Self::QuoteRejected => Some(2),
            Self::QuoteApproved => Some(3),
            Self::Printed => Some(4),
            Self::Received | Self::Cancelled => None,
        }
    }
}

/// Progress bar of the current batch, in order.
pub const BATCH_STEPS: [&str; 5] = [
    "Pronto",
    "Arquivos retirados",
    "Orçamento enviado",
    "Orçamento aprovado",
    "Impresso",
];

/// A batch quote: the sealed batch is immutable, so no order revision.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BatchQuote {
    pub id: String,
    pub revision: u64,
    pub amount_cents: i64,
    pub currency: Currency,
    pub document: FileRef,
    pub decision: QuoteDecision,
    pub rejection_reason: Option<String>,
    pub submitted_at: Instant,
    pub decided_at: Option<Instant>,
}

/// Residual legacy content: request-wide text and files without a safe
/// per-file job. Never guessed into a job.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GeneralInstructions {
    pub text: String,
    pub files: Vec<FileRef>,
}

// Missing is optional; explicit null is not a valid value for these keys.
fn present<'de, D: Deserializer<'de>, T: Deserialize<'de>>(d: D) -> Result<Option<T>, D::Error> {
    T::deserialize(d).map(Some)
}

/// One request (solicitação) of the batch, with its file jobs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BatchItem {
    pub order_id: String,
    pub reference: String,
    pub title: String,
    pub revision: u64,
    pub jobs: Vec<PrintJob>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present"
    )]
    pub general_instructions: Option<GeneralInstructions>,
    /// Latest cancelled batch this request was in (`LOT-0007`), from the
    /// backend; never inferred client-side.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present"
    )]
    pub previously_cancelled_in: Option<String>,
}
impl BatchItem {
    /// Every file of the item once: jobs first, then residual files.
    pub fn files(&self) -> impl Iterator<Item = &FileRef> {
        self.jobs.iter().map(|j| &j.file).chain(
            self.general_instructions
                .iter()
                .flat_map(|g| g.files.iter()),
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BatchSummary {
    pub id: String,
    pub reference: String,
    pub status: BatchStatus,
    pub version: u64,
    pub item_count: u64,
    pub created_at: Instant,
    pub collected_at: Option<Instant>,
    pub printed_at: Option<Instant>,
    pub received_at: Option<Instant>,
    pub approved_amount_cents: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Batch {
    pub id: String,
    pub reference: String,
    pub status: BatchStatus,
    pub version: u64,
    pub item_count: u64,
    pub created_at: Instant,
    pub collected_at: Option<Instant>,
    pub printed_at: Option<Instant>,
    pub received_at: Option<Instant>,
    pub approved_amount_cents: Option<i64>,
    pub items: Vec<BatchItem>,
    pub current_quote: Option<BatchQuote>,
    pub cancellation_reason: Option<String>,
}
impl Batch {
    pub fn summary(&self) -> BatchSummary {
        BatchSummary {
            id: self.id.clone(),
            reference: self.reference.clone(),
            status: self.status,
            version: self.version,
            item_count: self.item_count,
            created_at: self.created_at.clone(),
            collected_at: self.collected_at.clone(),
            printed_at: self.printed_at.clone(),
            received_at: self.received_at.clone(),
            approved_amount_cents: self.approved_amount_cents,
        }
    }
    pub fn copies(&self) -> u64 {
        self.items
            .iter()
            .flat_map(|i| &i.jobs)
            .map(|j| u64::from(j.copies))
            .sum()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BatchList {
    pub items: Vec<BatchSummary>,
    pub next_cursor: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BatchResponse {
    pub batch: Batch,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OpenBatchResponse {
    pub batch: Option<Batch>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CloseState {
    Open,
    Submitted,
    Rejected,
    Accepted,
}

/// A billed line of the monthly close: a whole batch quote, or a historic
/// individual order charge. No invented per-request share of a batch.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum CloseItem {
    Batch {
        batch_id: String,
        reference: String,
        quote_id: String,
        amount_cents: i64,
        printed_at: Instant,
    },
    LegacyOrder {
        order_id: String,
        reference: String,
        quote_id: String,
        amount_cents: i64,
        printed_at: Instant,
    },
}
impl CloseItem {
    pub fn reference(&self) -> &str {
        match self {
            Self::Batch { reference, .. } | Self::LegacyOrder { reference, .. } => reference,
        }
    }
    pub fn amount_cents(&self) -> i64 {
        match self {
            Self::Batch { amount_cents, .. } | Self::LegacyOrder { amount_cents, .. } => {
                *amount_cents
            }
        }
    }
    pub fn printed_at(&self) -> &Instant {
        match self {
            Self::Batch { printed_at, .. } | Self::LegacyOrder { printed_at, .. } => printed_at,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Close {
    pub id: Option<String>,
    pub competence: String,
    pub version: u64,
    pub state: CloseState,
    pub period_closed: bool,
    pub items: Vec<CloseItem>,
    pub expected_total_cents: i64,
    pub declared_total_cents: Option<i64>,
    pub document: Option<FileRef>,
    pub rejection_reason: Option<String>,
    pub submitted_at: Option<Instant>,
    pub accepted_at: Option<Instant>,
}
impl Close {
    /// The supplier may send an NF now (the upstream still decides).
    pub fn accepts_invoice(&self) -> bool {
        self.period_closed
            && !self.items.is_empty()
            && matches!(self.state, CloseState::Open | CloseState::Rejected)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CloseResponse {
    pub close: Close,
}

/// Schema constraints that serde's typing alone does not express.
pub trait Validate {
    fn validate(&self) -> Result<(), &'static str>;
}

fn check(ok: bool, what: &'static str) -> Result<(), &'static str> {
    if ok { Ok(()) } else { Err(what) }
}
fn cents(value: i64) -> bool {
    (1..=MAX_CENTS).contains(&value)
}
fn safe_positive(value: u64) -> bool {
    (1..=MAX_SAFE_INTEGER).contains(&value)
}
fn reference(value: &str, prefix: &str) -> bool {
    value
        .strip_prefix(prefix)
        .is_some_and(|d| d.len() >= 4 && d.bytes().all(|b| b.is_ascii_digit()))
}

impl Validate for FileRef {
    fn validate(&self) -> Result<(), &'static str> {
        check(is_uuid(&self.id), "file.id")?;
        check((1..=200).contains(&utf16_len(&self.name)), "file.name")?;
        check(!self.mime.is_empty(), "file.mime")?;
        check(safe_positive(self.bytes), "file.bytes")?;
        check(is_sha256_hex(&self.sha256), "file.sha256")
    }
}
impl Validate for PrintJob {
    fn validate(&self) -> Result<(), &'static str> {
        check(is_uuid(&self.id), "job.id")?;
        check((2..=160).contains(&utf16_len(&self.title)), "job.title")?;
        check((1..=500).contains(&self.copies), "job.copies")?;
        check(
            (5..=4000).contains(&utf16_len(&self.instructions)),
            "job.instructions",
        )?;
        self.file.validate()
    }
}
impl Validate for BatchQuote {
    fn validate(&self) -> Result<(), &'static str> {
        check(is_uuid(&self.id), "quote.id")?;
        check(safe_positive(self.revision), "quote.revision")?;
        check(cents(self.amount_cents), "quote.amountCents")?;
        self.document.validate()
    }
}
impl Validate for BatchItem {
    fn validate(&self) -> Result<(), &'static str> {
        check(is_uuid(&self.order_id), "item.orderId")?;
        check(reference(&self.reference, "IMP-"), "item.reference")?;
        check(!self.title.is_empty(), "item.title")?;
        check(safe_positive(self.revision), "item.revision")?;
        check(
            self.previously_cancelled_in
                .as_deref()
                .is_none_or(|r| reference(r, "LOT-")),
            "item.previouslyCancelledIn",
        )?;
        self.jobs.iter().try_for_each(Validate::validate)?;
        if let Some(general) = &self.general_instructions {
            general.files.iter().try_for_each(Validate::validate)?;
        }
        let ids: Vec<&str> = self.files().map(|f| f.id.as_str()).collect();
        check(!ids.is_empty(), "item.files")?;
        let unique: std::collections::HashSet<&str> = ids.iter().copied().collect();
        check(unique.len() == ids.len(), "item.files.unique")
    }
}
impl Validate for BatchSummary {
    fn validate(&self) -> Result<(), &'static str> {
        check(is_uuid(&self.id), "batch.id")?;
        check(reference(&self.reference, "LOT-"), "batch.reference")?;
        check(safe_positive(self.version), "batch.version")?;
        check(self.item_count <= MAX_SAFE_INTEGER, "batch.itemCount")?;
        check(
            self.approved_amount_cents.is_none_or(cents),
            "batch.approvedAmountCents",
        )
    }
}
impl Validate for Batch {
    fn validate(&self) -> Result<(), &'static str> {
        self.summary().validate()?;
        check(
            self.item_count == self.items.len() as u64,
            "batch.itemCount",
        )?;
        let orders: std::collections::HashSet<&str> =
            self.items.iter().map(|i| i.order_id.as_str()).collect();
        check(orders.len() == self.items.len(), "batch.items.unique")?;
        self.items.iter().try_for_each(Validate::validate)?;
        if let Some(quote) = &self.current_quote {
            quote.validate()?;
        }
        Ok(())
    }
}
impl Validate for BatchList {
    fn validate(&self) -> Result<(), &'static str> {
        self.items.iter().try_for_each(Validate::validate)
    }
}
impl Validate for BatchResponse {
    fn validate(&self) -> Result<(), &'static str> {
        self.batch.validate()
    }
}
impl Validate for OpenBatchResponse {
    fn validate(&self) -> Result<(), &'static str> {
        self.batch.as_ref().map_or(Ok(()), Validate::validate)
    }
}
impl Validate for CloseItem {
    fn validate(&self) -> Result<(), &'static str> {
        let (id, quote_id) = match self {
            Self::Batch {
                batch_id, quote_id, ..
            } => (batch_id, quote_id),
            Self::LegacyOrder {
                order_id, quote_id, ..
            } => (order_id, quote_id),
        };
        check(is_uuid(id), "item.id")?;
        check(is_uuid(quote_id), "item.quoteId")?;
        check(cents(self.amount_cents()), "item.amountCents")
    }
}
impl Validate for Close {
    fn validate(&self) -> Result<(), &'static str> {
        check(self.id.as_deref().is_none_or(is_uuid), "close.id")?;
        check(
            crate::Competence::parse(&self.competence).is_some(),
            "close.competence",
        )?;
        check(self.version <= MAX_SAFE_INTEGER, "close.version")?;
        check(
            (0..=MAX_CENTS).contains(&self.expected_total_cents),
            "close.expectedTotalCents",
        )?;
        check(
            self.declared_total_cents.is_none_or(cents),
            "close.declaredTotalCents",
        )?;
        if let Some(document) = &self.document {
            document.validate()?;
        }
        self.items.iter().try_for_each(Validate::validate)
    }
}
impl Validate for CloseResponse {
    fn validate(&self) -> Result<(), &'static str> {
        self.close.validate()
    }
}
