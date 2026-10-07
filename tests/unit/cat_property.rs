use frame::{
    CatRepository, CreateCatDeps, CreateCatInput, Observability, create_cat, name_length,
    parse_cat_name, trim_name,
};
use frame_memory::CatRepositoryMemory;
use proptest::prelude::*;

fn valid_name() -> impl Strategy<Value = String> {
    prop::collection::vec(any::<char>(), 1..=100)
        .prop_map(|v| v.into_iter().collect::<String>())
        .prop_filter("JS-trimmed UTF-16 length 1..100", |s| {
            !trim_name(s).is_empty() && name_length(trim_name(s)) <= 100
        })
}
proptest! {
    #![proptest_config(ProptestConfig::with_cases(50))]
    #[test]
    fn create_then_fetch_round_trip(name in valid_name()) {
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            let _guard = frame_testing::TestObservability::new();
            let repo = CatRepositoryMemory::default();
            let obs = Observability::default();
            let clock = || "2026-01-15T12:00:00Z".parse().unwrap();
            let input = CreateCatInput { id: uuid::Uuid::new_v4().to_string(), name };
            let created = create_cat(CreateCatDeps { cat_repository: &repo, clock: &clock, observability: &obs }, input).await.unwrap();
            assert_eq!(repo.find_by_id(&created.id).await.unwrap(), Some(created));
        });
    }
}
proptest! {
    #![proptest_config(ProptestConfig::with_cases(100))]
    #[test]
    fn names_longer_than_100_are_rejected(name in prop::collection::vec(any::<char>(), 101..=500).prop_map(|v| v.into_iter().collect::<String>()).prop_filter("trimmed UTF-16 > 100", |s| name_length(trim_name(s)) > 100)) {
        prop_assert!(parse_cat_name(&name).is_err());
    }
    #[test]
    fn valid_names_are_accepted(name in valid_name()) { prop_assert!(parse_cat_name(&name).is_ok()); }
}
