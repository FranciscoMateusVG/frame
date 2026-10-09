//! Print-portal domain: the frozen upstream DTOs (print-portal-v2 schema),
//! money, competence and text rules. Pure data + validation, no I/O.
mod batch;
mod competence;
mod money;
mod text;
pub use batch::*;
pub use competence::*;
pub use money::*;
pub use text::*;
