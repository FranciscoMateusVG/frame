//! Print-portal domain: the frozen upstream DTOs (print-portal-v1 schema),
//! money, competence and text rules. Pure data + validation, no I/O.
mod competence;
mod money;
mod order;
mod text;
pub use competence::*;
pub use money::*;
pub use order::*;
pub use text::*;
