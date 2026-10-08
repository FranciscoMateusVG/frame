use frame_portal_domain::*;
use proptest::prelude::*;

proptest! {
    #[test]
    fn displayed_brl_parses_back_to_the_same_cents(cents in 1i64..=99_999_999) {
        prop_assert_eq!(parse_brl(&format_brl(cents)), Some(cents));
    }

    #[test]
    fn canonical_cents_roundtrip(cents in 1i64..=MAX_CENTS) {
        prop_assert_eq!(parse_cents(&cents.to_string()), Some(cents));
    }

    #[test]
    fn content_disposition_never_carries_control_characters(name in any::<String>()) {
        let header = content_disposition(&name);
        prop_assert!(header.bytes().all(|b| (0x20..0x7f).contains(&b)));
        prop_assert!(header.starts_with("attachment; filename=\""));
        let decoded = disposition_filename(&header).unwrap();
        prop_assert_eq!(decoded, sanitize_download_name(&name));
    }

    #[test]
    fn sanitized_names_have_no_separators_or_controls(name in any::<String>()) {
        let clean = sanitize_download_name(&name);
        prop_assert!(!clean.is_empty());
        prop_assert!(!clean.contains('/') && !clean.contains('\\'));
        prop_assert!(!clean.chars().any(char::is_control));
        prop_assert!(clean.chars().count() <= 200);
    }

    #[test]
    fn competence_display_parses_back(year in 2000i32..=2998, month in 1u32..=12) {
        let raw = format!("{year:04}-{month:02}");
        let c = Competence::parse(&raw).unwrap();
        prop_assert_eq!(c.to_string(), raw);
        prop_assert_eq!(c.next().previous(), c);
        prop_assert!(Competence::containing(c.ends_at()) == c.next());
    }
}
