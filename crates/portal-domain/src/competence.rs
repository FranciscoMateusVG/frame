//! Monthly competence `YYYY-MM` in America/Sao_Paulo.
use chrono::{DateTime, Datelike, FixedOffset, NaiveDate, TimeZone, Utc};
use std::fmt;

/// Brazil has had no DST since 2019: São Paulo is a fixed UTC−03:00.
pub fn sao_paulo() -> FixedOffset {
    FixedOffset::west_opt(3 * 3600).expect("valid offset")
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Competence {
    year: i32,
    month: u32,
}

impl Competence {
    /// Strict `YYYY-MM`, years 2000–2999, months 01–12.
    pub fn parse(raw: &str) -> Option<Self> {
        let b = raw.as_bytes();
        if b.len() != 7 || b[4] != b'-' || !raw[..4].bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        if !raw[5..].bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        let year: i32 = raw[..4].parse().ok()?;
        let month: u32 = raw[5..].parse().ok()?;
        ((2000..=2999).contains(&year) && (1..=12).contains(&month)).then_some(Self { year, month })
    }
    /// The São Paulo month containing `at`.
    pub fn containing(at: DateTime<Utc>) -> Self {
        let local = at.with_timezone(&sao_paulo());
        Self {
            year: local.year(),
            month: local.month(),
        }
    }
    pub fn previous(self) -> Self {
        if self.month == 1 {
            Self {
                year: self.year - 1,
                month: 12,
            }
        } else {
            Self {
                year: self.year,
                month: self.month - 1,
            }
        }
    }
    pub fn next(self) -> Self {
        if self.month == 12 {
            Self {
                year: self.year + 1,
                month: 1,
            }
        } else {
            Self {
                year: self.year,
                month: self.month + 1,
            }
        }
    }
    /// First instant after the competence (local midnight of the next month).
    pub fn ends_at(self) -> DateTime<Utc> {
        let next = self.next();
        let date = NaiveDate::from_ymd_opt(next.year, next.month, 1).expect("valid month");
        sao_paulo()
            .from_local_datetime(&date.and_hms_opt(0, 0, 0).expect("midnight"))
            .single()
            .expect("fixed offset is unambiguous")
            .with_timezone(&Utc)
    }
    pub fn is_closed(self, now: DateTime<Utc>) -> bool {
        now >= self.ends_at()
    }
    /// Portuguese month label, e.g. `setembro de 2026`.
    pub fn label(self) -> String {
        const MONTHS: [&str; 12] = [
            "janeiro",
            "fevereiro",
            "março",
            "abril",
            "maio",
            "junho",
            "julho",
            "agosto",
            "setembro",
            "outubro",
            "novembro",
            "dezembro",
        ];
        format!("{} de {}", MONTHS[self.month as usize - 1], self.year)
    }
}

impl fmt::Display for Competence {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:04}-{:02}", self.year, self.month)
    }
}
