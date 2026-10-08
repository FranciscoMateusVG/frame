//! Supplier projection of the Incluir print-portal service API v1.
//! Shapes mirror `print-portal-v1.schema.json` exactly: unknown fields are
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

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrderStatus {
    Ready,
    FilesCollected,
    QuotePending,
    QuoteRejected,
    QuoteApproved,
    Printed,
    Cancelled,
}
impl OrderStatus {
    pub const ALL: [Self; 7] = [
        Self::Ready,
        Self::FilesCollected,
        Self::QuotePending,
        Self::QuoteRejected,
        Self::QuoteApproved,
        Self::Printed,
        Self::Cancelled,
    ];
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::FilesCollected => "files_collected",
            Self::QuotePending => "quote_pending",
            Self::QuoteRejected => "quote_rejected",
            Self::QuoteApproved => "quote_approved",
            Self::Printed => "printed",
            Self::Cancelled => "cancelled",
        }
    }
    pub fn parse(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.as_str() == raw)
    }
    /// Label shown to the print shop.
    pub fn label(self) -> &'static str {
        match self {
            Self::Ready => "Pronto para retirada",
            Self::FilesCollected => "Arquivos retirados",
            Self::QuotePending => "Aguardando aprovação do Financeiro",
            Self::QuoteRejected => "Orçamento rejeitado",
            Self::QuoteApproved => "Orçamento aprovado",
            Self::Printed => "Impresso",
            Self::Cancelled => "Cancelado",
        }
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

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Quote {
    pub id: String,
    pub revision: u64,
    pub order_revision: u64,
    pub amount_cents: i64,
    pub currency: Currency,
    pub document: FileRef,
    pub decision: QuoteDecision,
    pub rejection_reason: Option<String>,
    pub submitted_at: Instant,
    pub decided_at: Option<Instant>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OrderSummary {
    pub id: String,
    pub reference: String,
    pub title: String,
    pub revision: u64,
    pub version: u64,
    pub status: OrderStatus,
    pub created_at: Instant,
    pub collected_at: Option<Instant>,
    pub printed_at: Option<Instant>,
    pub approved_amount_cents: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Order {
    pub id: String,
    pub reference: String,
    pub title: String,
    pub revision: u64,
    pub version: u64,
    pub status: OrderStatus,
    pub created_at: Instant,
    pub collected_at: Option<Instant>,
    pub printed_at: Option<Instant>,
    pub approved_amount_cents: Option<i64>,
    pub jobs: Vec<PrintJob>,
    pub current_quote: Option<Quote>,
    pub cancellation_reason: Option<String>,
}
impl Order {
    pub fn summary(&self) -> OrderSummary {
        OrderSummary {
            id: self.id.clone(),
            reference: self.reference.clone(),
            title: self.title.clone(),
            revision: self.revision,
            version: self.version,
            status: self.status,
            created_at: self.created_at.clone(),
            collected_at: self.collected_at.clone(),
            printed_at: self.printed_at.clone(),
            approved_amount_cents: self.approved_amount_cents,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OrderList {
    pub items: Vec<OrderSummary>,
    pub next_cursor: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OrderResponse {
    pub order: Order,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CloseState {
    Open,
    Submitted,
    Rejected,
    Accepted,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CloseItem {
    pub order_id: String,
    pub reference: String,
    pub quote_id: String,
    pub amount_cents: i64,
    pub printed_at: Instant,
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
fn reference(value: &str) -> bool {
    value
        .strip_prefix("IMP-")
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
impl Validate for Quote {
    fn validate(&self) -> Result<(), &'static str> {
        check(is_uuid(&self.id), "quote.id")?;
        check(safe_positive(self.revision), "quote.revision")?;
        check(safe_positive(self.order_revision), "quote.orderRevision")?;
        check(cents(self.amount_cents), "quote.amountCents")?;
        self.document.validate()
    }
}
impl Validate for OrderSummary {
    fn validate(&self) -> Result<(), &'static str> {
        check(is_uuid(&self.id), "order.id")?;
        check(reference(&self.reference), "order.reference")?;
        check(!self.title.is_empty(), "order.title")?;
        check(safe_positive(self.revision), "order.revision")?;
        check(safe_positive(self.version), "order.version")?;
        check(
            self.approved_amount_cents.is_none_or(cents),
            "order.approvedAmountCents",
        )
    }
}
impl Validate for Order {
    fn validate(&self) -> Result<(), &'static str> {
        self.summary().validate()?;
        check(!self.jobs.is_empty(), "order.jobs")?;
        for job in &self.jobs {
            job.validate()?;
        }
        if let Some(quote) = &self.current_quote {
            quote.validate()?;
        }
        Ok(())
    }
}
impl Validate for OrderList {
    fn validate(&self) -> Result<(), &'static str> {
        self.items.iter().try_for_each(Validate::validate)
    }
}
impl Validate for OrderResponse {
    fn validate(&self) -> Result<(), &'static str> {
        self.order.validate()
    }
}
impl Validate for CloseItem {
    fn validate(&self) -> Result<(), &'static str> {
        check(is_uuid(&self.order_id), "item.orderId")?;
        check(is_uuid(&self.quote_id), "item.quoteId")?;
        check(cents(self.amount_cents), "item.amountCents")
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
