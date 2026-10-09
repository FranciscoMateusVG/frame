//! Server-rendered HTML (spec §7): `/login`, `/` (the current batch),
//! `/batches` + `/batches/:id` (history), `/invoices`. maud escapes every
//! interpolation. Commands are sent by `/assets/portal.js` to the JSON API
//! with CSRF + If-Match + Idempotency-Key; pages only read. No session →
//! redirect to `/login` (internal `next` paths only). `data-ttp` markers
//! (the shared TTP smoke contract) sit on the real rendered components.
use crate::AppState;
use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Redirect, Response},
};
use chrono::{DateTime, Utc};
use frame_portal_domain::{
    BATCH_STEPS, Batch, BatchItem, BatchList, BatchStatus, Close, CloseItem, CloseState,
    Competence, FileRef, Instant, QuoteDecision, format_brl, is_uuid, sao_paulo,
};
use frame_portal_port::{ApiError, codes};
use frame_portal_use_cases::{get_batch, get_current_batch, get_monthly_close, list_batches};
use maud::{DOCTYPE, Markup, html};
use std::{collections::HashMap, sync::Arc};

type AppStateRef = State<Arc<AppState>>;

fn when(at: &Instant) -> String {
    local(at.to_utc())
}
fn local(at: DateTime<Utc>) -> String {
    at.with_timezone(&sao_paulo())
        .format("%d/%m/%Y %H:%M")
        .to_string()
}

fn page(title: &str, csrf: &str, signed_in: bool, body: Markup) -> Markup {
    html! {
        (DOCTYPE)
        html lang="pt-BR" {
            head {
                meta charset="utf-8";
                meta name="viewport" content="width=device-width, initial-scale=1";
                meta name="csrf-token" content=(csrf);
                title { (title) " · Portal da gráfica" }
                link rel="stylesheet" href="/assets/portal.css";
                script src="/assets/portal.js" defer {}
            }
            body {
                header.top {
                    span.brand { "Portal da gráfica" }
                    @if signed_in {
                        nav {
                            a href="/" { "Lote atual" }
                            a href="/batches" { "Lotes anteriores" }
                            a href="/invoices" { "Notas fiscais" }
                            button type="button" id="logout" { "Sair" }
                        }
                    }
                }
                main { (body) }
            }
        }
    }
}

fn respond(markup: Markup) -> Response {
    let mut response = markup.into_response();
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

/// Internal destinations only (no open redirect).
fn safe_next(raw: Option<&String>) -> Option<String> {
    let raw = raw?;
    let ok = ["/", "/batches", "/invoices"].contains(&raw.as_str())
        || raw.strip_prefix("/batches/").is_some_and(is_uuid);
    ok.then(|| raw.clone())
}

fn to_login(next: &str) -> Response {
    Redirect::to(&format!(
        "/login?next={}",
        frame_portal_domain::percent_encode(next)
    ))
    .into_response()
}

pub async fn login_page(
    State(state): AppStateRef,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let next = safe_next(query.get("next"));
    if state.session(&headers).is_some() {
        return Redirect::to(next.as_deref().unwrap_or("/")).into_response();
    }
    let (presession, set) = state.presession(&headers);
    let body = html! {
        section.card.narrow {
            h1 { "Entrar" }
            p.muted { "Acesso da gráfica parceira do Programa Incluir." }
            form #login data-next=(next.as_deref().unwrap_or("/")) {
                label for="password" { "Senha" }
                input #password type="password" name="password" autocomplete="current-password" required;
                button type="submit" { "Entrar" }
            }
            p #message role="alert" {}
        }
    };
    let mut response = respond(page("Entrar", &presession.csrf, false, body));
    if let Some(set) = set {
        response.headers_mut().append(header::SET_COOKIE, set);
    }
    response
}

fn unavailable(retry_href: &str) -> Markup {
    html! {
        div.notice.error role="alert" {
            p { "Não foi possível consultar o serviço agora. Nenhuma alteração foi feita." }
            a.button href=(retry_href) { "Consultar novamente" }
        }
    }
}

fn unavailable_page(state_csrf: &str, title: &str, here: &str) -> Response {
    let mut response = respond(page(
        title,
        state_csrf,
        true,
        html! { section.card { h1 { (title) } (unavailable(here)) } },
    ));
    *response.status_mut() = StatusCode::SERVICE_UNAVAILABLE;
    response
}

/// Home: the single current batch (open or active), or the empty state.
pub async fn home(State(state): AppStateRef, headers: HeaderMap) -> Response {
    let Some(session) = state.session(&headers) else {
        return Redirect::to("/login").into_response();
    };
    match get_current_batch(state.print()).await {
        Ok(Some(tagged)) => respond(page(
            &tagged.body.reference,
            &session.csrf,
            true,
            batch_view(&tagged.body, Some(&tagged.etag)),
        )),
        Ok(None) => respond(page(
            "Lote atual",
            &session.csrf,
            true,
            html! {
                section.card {
                    h1 { "Lote atual" }
                    p.empty data-ttp="empty" { "Nenhum pedido aguardando" }
                    p.muted { "Quando o Incluir publicar novas solicitações, elas aparecem aqui como um lote." }
                    a.button.secondary href="/batches" { "Ver lotes anteriores" }
                }
            },
        )),
        Err(_) => unavailable_page(&session.csrf, "Lote atual", "/"),
    }
}

fn size(bytes: u64) -> String {
    if bytes >= 1024 * 1024 {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.0} KB", bytes as f64 / 1024.0)
    } else {
        format!("{bytes} B")
    }
}

fn confirm(question: &str, yes: &str) -> Markup {
    html! {
        div.confirm hidden {
            p { (question) }
            button type="button" data-confirm { (yes) }
            button type="button" class="secondary" data-cancel { "Voltar" }
        }
    }
}

fn recovery() -> Markup {
    html! {
        div.recovery hidden {
            p { "O serviço não confirmou a operação. Consulte o estado antes de repetir." }
            a.button href="" data-reload { "Atualizar" }
            button type="button" class="secondary" data-retry { "Repetir envio" }
        }
    }
}

fn progress(status: BatchStatus) -> Markup {
    html! {
        @if let Some(reached) = status.progress() {
            ol.progress aria-label="Andamento do lote" {
                @for (i, step) in BATCH_STEPS.iter().enumerate() {
                    li class=@if i < reached { "done" } @else if i == reached { "current" } @else { "" }
                        aria-current=[(i == reached).then_some("step")] { (step) }
                }
            }
        }
    }
}

fn file_href(batch: &Batch, item: &BatchItem, file: &FileRef) -> String {
    format!(
        "/api/print/v2/batches/{}/orders/{}/files/{}",
        batch.id, item.order_id, file.id
    )
}

fn file_head(file: &FileRef) -> Markup {
    html! {
        h4.file-name data-ttp="file-name" { (file.name) }
        p.muted { span data-ttp="file-size" data-bytes=(file.bytes) { (size(file.bytes)) } }
    }
}

fn item_view(batch: &Batch, item: &BatchItem) -> Markup {
    let general = item.general_instructions.as_ref();
    html! {
        article.request data-ttp="item" data-order-id=(item.order_id) {
            h2 { span data-ttp="item-reference" { (item.reference) } " · " (item.title) }
            @if let Some(lot) = &item.previously_cancelled_in {
                p.notice.warn data-ttp="previously-cancelled" {
                    "Este item já esteve no lote " strong { (lot) } ", cancelado — confira antes de imprimir."
                }
            }
            div.cards {
                @for job in &item.jobs {
                    article.file-card data-ttp="file" data-file-id=(job.file.id) {
                        p.job-title { (job.title) }
                        (file_head(&job.file))
                        p { "Cópias: " strong data-ttp="copies" { (job.copies) } }
                        p.instructions data-ttp="instructions" { (job.instructions) }
                        @if let Some(lot) = &item.previously_cancelled_in {
                            p.muted { "Esteve no lote " (lot) " (cancelado)." }
                        }
                        a.button.secondary data-ttp="download" href=(file_href(batch, item, &job.file)) download { "Baixar arquivo" }
                    }
                }
                @for file in general.map(|g| g.files.as_slice()).unwrap_or_default() {
                    article.file-card.residual data-ttp="file" data-file-id=(file.id) {
                        p.job-title { "Não identificadas" }
                        (file_head(file))
                        p.muted { "Sem vínculo seguro — consulte instruções gerais" }
                        a.button.secondary data-ttp="download" href=(file_href(batch, item, file)) download { "Baixar arquivo" }
                    }
                }
            }
            @if let Some(general) = general {
                section.general {
                    h3 { "Instruções gerais" }
                    p.muted { "Valem para esta solicitação inteira, sem vínculo com um arquivo específico." }
                    p.instructions data-ttp="general-instructions" { (general.text) }
                    @if general.text.is_empty() { p.muted { "Sem texto adicional." } }
                }
            }
        }
    }
}

fn file_count(batch: &Batch) -> usize {
    batch.items.iter().map(|i| i.files().count()).sum()
}

fn collect_question(files: usize, requests: usize) -> String {
    let files = if files == 1 {
        "o arquivo".to_owned()
    } else {
        format!("os {files} arquivos")
    };
    let requests = if requests == 1 {
        "1 solicitação".to_owned()
    } else {
        format!("{requests} solicitações")
    };
    format!("Confirma que retirou {files} deste lote ({requests})?")
}

/// The supplier's next step for the batch status. Actions not allowed in a
/// state are not rendered at all.
fn actions(batch: &Batch, etag: &str) -> Markup {
    let quote = batch.current_quote.as_ref();
    let files = file_count(batch);
    html! {
        section #actions
            data-batch-id=(batch.id)
            data-etag=(etag)
            data-quote-id=(quote.map(|q| q.id.as_str()).unwrap_or("")) {
            h2 { "Próximo passo" }
            @if let Some(q) = quote {
                div.quote {
                    p { strong { "Orçamento " (q.revision) ": " } (format_brl(q.amount_cents)) " · enviado em " (when(&q.submitted_at)) }
                    a.button.secondary href={"/api/print/v2/batches/" (batch.id) "/quotes/" (q.id) "/file"} download { "Baixar orçamento" }
                    @if q.decision == QuoteDecision::Rejected {
                        div.notice.error { p { strong { "Orçamento rejeitado." } " Motivo: " (q.rejection_reason.as_deref().unwrap_or("—")) } }
                    }
                }
            }
            @match batch.status {
                BatchStatus::Open => {
                    form data-action="collect" {
                        label.check { input type="checkbox" name="checked" required; " Conferi todos os arquivos" }
                        button type="submit" data-ttp="action" data-action="collect" { "Retirei os arquivos" }
                        (confirm(&collect_question(files, batch.items.len()), "Confirmar retirada"))
                    }
                }
                BatchStatus::FilesCollected | BatchStatus::QuoteRejected => {
                    form data-action="upload-quote" {
                        label for="amount" { "Valor total do lote (R$)" }
                        input #amount name="amount" inputmode="decimal" placeholder="0,00" autocomplete="off" required;
                        label for="quote-file" { "Arquivo do orçamento" }
                        input #quote-file type="file" name="file" accept=".pdf,.jpg,.jpeg,.png,.webp,application/pdf,image/jpeg,image/png,image/webp" required;
                        p.muted { "PDF, JPEG, PNG ou WebP, até 5 MB. Um orçamento para o lote inteiro." }
                        button type="submit" data-ttp="action" data-action="upload-quote" { "Enviar orçamento" }
                        (confirm("Confirma o envio deste orçamento para o lote inteiro?", "Confirmar envio"))
                    }
                }
                BatchStatus::QuotePending => {
                    p.notice data-ttp="status-message" { "Aguardando aprovação do Financeiro" }
                }
                BatchStatus::QuoteApproved => {
                    p.notice.ok { "Orçamento aprovado." }
                    form data-action="mark-printed" {
                        button type="submit" data-ttp="action" data-action="mark-printed" { "Marcar como impresso" }
                        (confirm("Confirma que a impressão do lote inteiro foi concluída?", "Confirmar impressão"))
                    }
                }
                BatchStatus::Printed => {
                    p.notice.ok data-ttp="status-message" { "Aguardando recebimento" }
                }
                BatchStatus::Received | BatchStatus::Cancelled => {}
            }
            (recovery())
            p #message role="status" aria-live="polite" {}
        }
    }
}

/// One batch with its request/file cards; `etag` = current batch with
/// actions, `None` = read-only history detail.
fn batch_view(batch: &Batch, etag: Option<&str>) -> Markup {
    html! {
        section.card.batch data-ttp="batch" data-batch-id=(batch.id) data-status=(batch.status.as_str()) {
            div.row {
                h1 { "Lote " span data-ttp="batch-reference" { (batch.reference) } }
                @if etag.is_some() {
                    a.button.secondary href="/" { "Atualizar" }
                } @else {
                    a.button.secondary href="/batches" { "Voltar aos lotes" }
                }
            }
            dl.facts {
                dt { "Status" } dd { span class={"badge " (batch.status.as_str())} { (batch.status.label()) } }
                dt { "Itens" } dd { (batch.item_count) }
                dt { "Arquivos" } dd { (file_count(batch)) }
                dt { "Cópias" } dd { (batch.copies()) }
                dt { "Criado em" } dd { (when(&batch.created_at)) }
                @if let Some(at) = &batch.collected_at { dt { "Arquivos retirados em" } dd { (when(at)) } }
                @if let Some(at) = &batch.printed_at { dt { "Impresso em" } dd { (when(at)) } }
                @if let Some(at) = &batch.received_at { dt { "Recebido em" } dd { (when(at)) } }
                @if let Some(cents) = batch.approved_amount_cents { dt { "Valor aprovado" } dd { (format_brl(cents)) } }
            }
            (progress(batch.status))
            @if let Some(reason) = &batch.cancellation_reason {
                div.notice.error { p { strong { "Lote cancelado." } " Motivo: " (reason) } }
            }
            @if let Some(etag) = etag {
                (actions(batch, etag))
            }
            @for item in &batch.items {
                (item_view(batch, item))
            }
        }
    }
}

/// `trail` holds the cursors of earlier pages ('~' = first page).
fn page_href(cursor: Option<&str>, trail: &[String]) -> String {
    let mut params = vec![];
    if let Some(c) = cursor {
        params.push(format!("cursor={}", frame_portal_domain::percent_encode(c)));
    }
    if !trail.is_empty() {
        params.push(format!(
            "trail={}",
            frame_portal_domain::percent_encode(&trail.join("."))
        ));
    }
    if params.is_empty() {
        "/batches".into()
    } else {
        format!("/batches?{}", params.join("&"))
    }
}

/// History ("Lotes anteriores"): every batch, oldest first, paged.
pub async fn batches_page(
    State(state): AppStateRef,
    headers: HeaderMap,
    Query(raw): Query<HashMap<String, String>>,
) -> Response {
    let Some(session) = state.session(&headers) else {
        return to_login("/batches");
    };
    let cursor = raw
        .get("cursor")
        .filter(|c| (1..=512).contains(&c.len()))
        .cloned();
    let trail: Vec<String> = raw
        .get("trail")
        .map(|t| {
            t.split('.')
                .filter(|s| !s.is_empty())
                .take(50)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    let query = frame_portal_port::ListQuery {
        status: None,
        limit: Some(20),
        cursor: cursor.clone(),
    };
    let here = page_href(cursor.as_deref(), &trail);
    let result = list_batches(state.print(), query).await;
    let content = match &result {
        Ok(list) => batches_table(list, cursor.as_deref(), &trail),
        Err(ApiError::Rejected { code, .. }) if code == codes::INVALID_CURSOR => html! {
            div.notice role="alert" {
                p { "A paginação expirou." }
                a.button href="/batches" { "Voltar ao início" }
            }
        },
        Err(_) => unavailable(&here),
    };
    let body = html! {
        section.card {
            div.row {
                h1 { "Lotes anteriores" }
                a.button.secondary href=(here) { "Atualizar" }
            }
            (content)
        }
    };
    let mut response = respond(page("Lotes anteriores", &session.csrf, true, body));
    match &result {
        Ok(_) => {}
        Err(ApiError::Rejected { status, .. }) => {
            *response.status_mut() =
                StatusCode::from_u16(*status).unwrap_or(StatusCode::BAD_REQUEST);
        }
        Err(ApiError::Unavailable { .. }) => {
            *response.status_mut() = StatusCode::SERVICE_UNAVAILABLE;
        }
    }
    response
}

fn batches_table(list: &BatchList, cursor: Option<&str>, trail: &[String]) -> Markup {
    let back = trail.last().map(|prev| {
        let rest = &trail[..trail.len() - 1];
        let prev = (prev != "~").then_some(prev.as_str());
        page_href(prev, rest)
    });
    let forward = list.next_cursor.as_deref().map(|next| {
        let mut trail = trail.to_vec();
        trail.push(cursor.unwrap_or("~").to_owned());
        page_href(Some(next), &trail)
    });
    let date = |at: &Option<Instant>| at.as_ref().map(when).unwrap_or_else(|| "—".into());
    html! {
        @if list.items.is_empty() {
            p.empty { "Nenhum lote ainda." }
        } @else {
            table.list {
                thead { tr { th { "Lote" } th { "Status" } th { "Itens" } th { "Criado em" } th { "Retirado em" } th { "Impresso em" } th { "Recebido em" } th { "Valor aprovado" } } }
                tbody {
                    @for b in &list.items {
                        tr {
                            td data-label="Lote" { a href={"/batches/" (b.id)} { (b.reference) } }
                            td data-label="Status" { span class={"badge " (b.status.as_str())} { (b.status.label()) } }
                            td data-label="Itens" { (b.item_count) }
                            td data-label="Criado em" { (when(&b.created_at)) }
                            td data-label="Retirado em" { (date(&b.collected_at)) }
                            td data-label="Impresso em" { (date(&b.printed_at)) }
                            td data-label="Recebido em" { (date(&b.received_at)) }
                            td data-label="Valor aprovado" { (b.approved_amount_cents.map(format_brl).unwrap_or_else(|| "—".into())) }
                        }
                    }
                }
            }
        }
        nav.pager {
            @if let Some(href) = back { a.button.secondary href=(href) { "Anterior" } }
            @if let Some(href) = forward { a.button.secondary href=(href) { "Próxima" } }
        }
    }
}

/// Read-only detail of any batch, with the same cards as the home screen.
pub async fn batch_page(
    State(state): AppStateRef,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    if !is_uuid(&id) {
        return not_found_page(&state, &headers);
    }
    let Some(session) = state.session(&headers) else {
        return to_login(&format!("/batches/{id}"));
    };
    match get_batch(state.print(), &id).await {
        Ok(tagged) => respond(page(
            &tagged.body.reference,
            &session.csrf,
            true,
            batch_view(&tagged.body, None),
        )),
        Err(ApiError::Rejected { status: 404, .. }) => not_found_page(&state, &headers),
        Err(_) => unavailable_page(&session.csrf, "Lote", &format!("/batches/{id}")),
    }
}

fn not_found_page(state: &AppState, headers: &HeaderMap) -> Response {
    let session = state.session(headers);
    let body = html! {
        section.card {
            h1 { "Não encontrado" }
            p { "Este endereço não existe ou não está disponível para a gráfica." }
            a.button href="/" { "Ir para o lote atual" }
        }
    };
    let csrf = session.as_ref().map(|s| s.csrf.as_str()).unwrap_or("");
    let mut response = respond(page("Não encontrado", csrf, session.is_some(), body));
    *response.status_mut() = StatusCode::NOT_FOUND;
    response
}

pub async fn fallback(State(state): AppStateRef, headers: HeaderMap) -> Response {
    not_found_page(&state, &headers)
}

pub async fn invoices_page(
    State(state): AppStateRef,
    headers: HeaderMap,
    Query(raw): Query<HashMap<String, String>>,
) -> Response {
    let Some(session) = state.session(&headers) else {
        return to_login("/invoices");
    };
    let now = (state.clock)();
    let current = Competence::containing(now);
    let competence = raw
        .get("competence")
        .and_then(|c| Competence::parse(c))
        .unwrap_or_else(|| current.previous());
    let here = format!("/invoices?competence={competence}");
    let result = get_monthly_close(state.print(), competence).await;
    let content = match &result {
        Ok(tagged) => close_view(&tagged.body, &tagged.etag, competence),
        Err(ApiError::Rejected { status: 404, .. }) => html! {
            div.notice role="status" {
                p { strong { "Notas fiscais ainda indisponíveis." } }
                p { "O envio da NF mensal ainda não foi habilitado no Incluir. O lote atual continua disponível na página inicial." }
            }
        },
        Err(_) => unavailable(&here),
    };
    let body = html! {
        section.card {
            div.row {
                h1 { "Notas fiscais" }
                a.button.secondary href=(here) { "Atualizar" }
            }
            p.muted {
                "A NF mensal reúne os lotes impressos na competência (mês no horário de Brasília) e só pode ser enviada depois do fim do mês."
            }
            form.filters method="get" action="/invoices" {
                a.button.secondary href={"/invoices?competence=" (competence.previous())} { "Mês anterior" }
                label for="competence" { "Competência" }
                input #competence type="month" name="competence" value=(competence.to_string()) required;
                button type="submit" { "Consultar" }
                @if competence < current {
                    a.button.secondary href={"/invoices?competence=" (competence.next())} { "Próximo mês" }
                }
            }
            h2 { (competence.label()) }
            (content)
        }
    };
    let mut response = respond(page("Notas fiscais", &session.csrf, true, body));
    if matches!(result, Err(ApiError::Unavailable { .. })) {
        *response.status_mut() = StatusCode::SERVICE_UNAVAILABLE;
    }
    response
}

fn close_view(close: &Close, etag: &str, competence: Competence) -> Markup {
    let diverges = close
        .declared_total_cents
        .is_some_and(|d| d != close.expected_total_cents);
    html! {
        @if !close.period_closed {
            p.notice { "Competência em andamento. A NF poderá ser enviada a partir de " (local(competence.ends_at())) "." }
        }
        @match close.state {
            CloseState::Open => {}
            CloseState::Submitted => { p.notice { "Aguardando conferência do Financeiro." } }
            CloseState::Rejected => {
                div.notice.error { p { strong { "NF rejeitada." } " Motivo: " (close.rejection_reason.as_deref().unwrap_or("—")) } }
            }
            CloseState::Accepted => {
                p.notice.ok { "NF aceita" @if let Some(at) = &close.accepted_at { " em " (when(at)) } "." }
            }
        }
        @if close.items.is_empty() {
            p.empty { "Nenhum lote impresso nesta competência." }
        } @else {
            table.list {
                thead { tr { th { "Lote ou pedido" } th { "Impresso em" } th { "Valor aprovado" } } }
                tbody {
                    @for item in &close.items {
                        tr {
                            td data-label="Lote ou pedido" {
                                @match item {
                                    CloseItem::Batch { batch_id, reference, .. } => { a href={"/batches/" (batch_id)} { (reference) } }
                                    CloseItem::LegacyOrder { reference, .. } => { (reference) " " span.muted { "(pedido individual)" } }
                                }
                            }
                            td data-label="Impresso em" { (when(item.printed_at())) }
                            td data-label="Valor aprovado" { (format_brl(item.amount_cents())) }
                        }
                    }
                }
            }
        }
        dl.facts {
            dt { "Total calculado" } dd.total { (format_brl(close.expected_total_cents)) }
            @if let Some(declared) = close.declared_total_cents {
                dt { "Valor declarado na NF" } dd class=@if diverges { "diverges" } @else { "" } { (format_brl(declared)) }
            }
            @if let Some(at) = &close.submitted_at { dt { "Enviada em" } dd { (when(at)) } }
        }
        @if diverges {
            p.notice.error { "O valor declarado diverge do total calculado. O Financeiro não aceita NF divergente." }
        }
        @if let Some(document) = &close.document {
            p { a.button.secondary href={"/api/print/v2/monthly-closes/" (competence) "/invoice"} download { "Baixar NF enviada" } " " span.muted { (document.name) } }
        }
        @if close.accepts_invoice() {
            div #actions data-competence=(competence.to_string()) data-etag=(etag) {
                form data-action="invoice" {
                    label for="declared" { "Valor total da NF" }
                    input #declared name="declared" inputmode="decimal" placeholder="0,00" autocomplete="off" required;
                    label for="invoice-file" { "Arquivo da NF" }
                    input #invoice-file type="file" name="file" accept=".pdf,.jpg,.jpeg,.png,.webp,application/pdf,image/jpeg,image/png,image/webp" required;
                    p.muted { "PDF, JPEG, PNG ou WebP, até 5 MB." }
                    button type="submit" { "Enviar NF" }
                    (confirm("Confirma o envio desta NF para conferência?", "Confirmar envio"))
                }
                (recovery())
                p #message role="status" aria-live="polite" {}
            }
        }
    }
}
