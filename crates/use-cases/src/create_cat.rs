use frame_domain::{Cat, CreateCatInput, name_length, parse_create_cat_input};
use frame_errors::{Error, InvalidCatNameError};
use frame_observability::{Observability, in_span};
use frame_port::CatRepository;
use opentelemetry::{Context, KeyValue, trace::TraceContextExt};

pub struct CreateCatDeps<'a> {
    pub cat_repository: &'a dyn CatRepository,
    pub clock: &'a (dyn Fn() -> frame_domain::Timestamp + Send + Sync),
    pub observability: &'a Observability,
}

/// Boundary validation, explicit dependencies, and no infrastructure construction.
pub async fn create_cat(deps: CreateCatDeps<'_>, input: CreateCatInput) -> Result<Cat, Error> {
    in_span(&deps.observability.tracer, "createCat", vec![], async {
        let input =
            parse_create_cat_input(input).map_err(|reason| InvalidCatNameError { reason })?;
        Context::current().span().set_attributes([
            KeyValue::new("cat.id", input.id.clone()),
            KeyValue::new("cat.name.length", name_length(&input.name) as i64),
        ]);
        let cat = Cat {
            id: input.id,
            name: input.name,
            created_at: (deps.clock)(),
        };
        deps.cat_repository.save(&cat).await?;
        let attrs = [
            ("catId".into(), cat.id.clone().into()),
            ("nameLength".into(), name_length(&cat.name).into()),
        ]
        .into_iter()
        .collect();
        deps.observability.logger.info("cat.created", Some(&attrs));
        Ok(cat)
    })
    .await
}
