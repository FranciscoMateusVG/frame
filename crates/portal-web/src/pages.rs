//! Server-rendered HTML (spec §7): `/login`, `/orders`, `/orders/:id`,
//! `/invoices`. maud escapes every interpolation. Commands are sent by
//! `/assets/portal.js` to the JSON API with CSRF + If-Match +
//! Idempotency-Key; pages only read. No session → redirect to `/login`
//! (internal `next` paths only).
use crate::AppState;
use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Redirect, Response},
};
use chrono::{DateTime, Utc};
use frame_portal_domain::{
    Close, CloseState, Competence, Instant, Order, OrderList, OrderStatus, QuoteDecision,
    format_brl, is_uuid, sao_paulo,
};
use frame_portal_port::{ApiError, codes};
use frame_portal_use_cases::{get_monthly_close, get_order, list_orders};
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
                            a href="/orders" { "Pedidos" }
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
    let ok =
        raw == "/orders" || raw == "/invoices" || raw.strip_prefix("/orders/").is_some_and(is_uuid);
    ok.then(|| raw.clone())
}

fn to_login(next: &str) -> Response {
    Redirect::to(&format!(
        "/login?next={}",
        frame_portal_domain::percent_encode(next)
    ))
    .into_response()
}

pub async fn root(State(state): AppStateRef, headers: HeaderMap) -> Response {
    let target = if state.session(&headers).is_some() {
        "/orders"
    } else {
        "/login"
    };
    Redirect::to(target).into_response()
}

pub async fn login_page(
    State(state): AppStateRef,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let next = safe_next(query.get("next"));
    if state.session(&headers).is_some() {
        return Redirect::to(next.as_deref().unwrap_or("/orders")).into_response();
    }
    let (presession, set) = state.presession(&headers);
    let body = html! {
        section.card.narrow {
            h1 { "Entrar" }
            p.muted { "Acesso da gráfica parceira do Programa Incluir." }
            form #login data-next=(next.as_deref().unwrap_or("/orders")) {
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

/// `trail` holds the cursors of earlier pages ('~' = first page).
fn page_href(status: Option<OrderStatus>, cursor: Option<&str>, trail: &[String]) -> String {
    let mut params = vec![];
    if let Some(s) = status {
        params.push(format!("status={}", s.as_str()));
    }
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
        "/orders".into()
    } else {
        format!("/orders?{}", params.join("&"))
    }
}

pub async fn orders_page(
    State(state): AppStateRef,
    headers: HeaderMap,
    Query(raw): Query<HashMap<String, String>>,
) -> Response {
    let Some(session) = state.session(&headers) else {
        return to_login("/orders");
    };
    let status = raw.get("status").and_then(|s| OrderStatus::parse(s));
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
        status,
        limit: Some(20),
        cursor: cursor.clone(),
    };
    let here = page_href(status, cursor.as_deref(), &trail);
    let result = list_orders(state.print(), query).await;
    let content = match &result {
        Ok(list) => orders_table(list, status, cursor.as_deref(), &trail),
        Err(ApiError::Rejected { code, .. }) if code == codes::INVALID_CURSOR => html! {
            div.notice role="alert" {
                p { "A paginação expirou." }
                a.button href=(page_href(status, None, &[])) { "Voltar ao início" }
            }
        },
        Err(_) => unavailable(&here),
    };
    let body = html! {
        section.card {
            div.row {
                h1 { "Pedidos" }
                a.button.secondary href=(here) { "Atualizar" }
            }
            form.filters method="get" action="/orders" {
                label for="status" { "Status" }
                select #status name="status" {
                    option value="" selected[status.is_none()] { "Todos" }
                    @for s in OrderStatus::ALL {
                        option value=(s.as_str()) selected[status == Some(s)] { (s.label()) }
                    }
                }
                button type="submit" { "Filtrar" }
            }
            (content)
        }
    };
    let mut response = respond(page("Pedidos", &session.csrf, true, body));
    if result.is_err() {
        *response.status_mut() = StatusCode::SERVICE_UNAVAILABLE;
        if let Err(ApiError::Rejected { status, .. }) = &result {
            *response.status_mut() =
                StatusCode::from_u16(*status).unwrap_or(StatusCode::BAD_REQUEST);
        }
    }
    response
}

fn orders_table(
    list: &OrderList,
    status: Option<OrderStatus>,
    cursor: Option<&str>,
    trail: &[String],
) -> Markup {
    let back = trail.last().map(|prev| {
        let rest = &trail[..trail.len() - 1];
        let prev = (prev != "~").then_some(prev.as_str());
        page_href(status, prev, rest)
    });
    let forward = list.next_cursor.as_deref().map(|next| {
        let mut trail = trail.to_vec();
        trail.push(cursor.unwrap_or("~").to_owned());
        page_href(status, Some(next), &trail)
    });
    html! {
        @if list.items.is_empty() {
            p.empty { "Nenhum pedido" @if status.is_some() { " com este status" } "." }
        } @else {
            table.list {
                thead { tr { th { "Referência" } th { "Título" } th { "Status" } th { "Criado em" } th { "Valor aprovado" } th {} } }
                tbody {
                    @for o in &list.items {
                        tr {
                            td data-label="Referência" { (o.reference) }
                            td data-label="Título" { (o.title) }
                            td data-label="Status" { span class={"badge " (o.status.as_str())} { (o.status.label()) } }
                            td data-label="Criado em" { (when(&o.created_at)) }
                            td data-label="Valor aprovado" { (o.approved_amount_cents.map(format_brl).unwrap_or_else(|| "—".into())) }
                            td { a.button href={"/orders/" (o.id)} { "Ver pedido" } }
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

pub async fn order_page(
    State(state): AppStateRef,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    if !is_uuid(&id) {
        return not_found_page(&state, &headers);
    }
    let Some(session) = state.session(&headers) else {
        return to_login(&format!("/orders/{id}"));
    };
    let here = format!("/orders/{id}");
    match get_order(state.print(), &id).await {
        Ok(tagged) => respond(page(
            &tagged.body.reference,
            &session.csrf,
            true,
            order_view(&tagged.body, &tagged.etag),
        )),
        Err(ApiError::Rejected { status: 404, .. }) => not_found_page(&state, &headers),
        Err(_) => {
            let mut response = respond(page(
                "Pedido",
                &session.csrf,
                true,
                html! { section.card { h1 { "Pedido" } (unavailable(&here)) } },
            ));
            *response.status_mut() = StatusCode::SERVICE_UNAVAILABLE;
            response
        }
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
            a.button href="" data-reload { "Consultar novamente" }
            button type="button" class="secondary" data-retry { "Repetir envio" }
        }
    }
}

fn order_view(order: &Order, etag: &str) -> Markup {
    let quote = order.current_quote.as_ref();
    html! {
        section.card {
            div.row {
                h1 { (order.reference) " · " (order.title) }
                a.button.secondary href={"/orders/" (order.id)} { "Atualizar" }
            }
            dl.facts {
                dt { "Status" } dd { span class={"badge " (order.status.as_str())} { (order.status.label()) } }
                dt { "Revisão" } dd { (order.revision) }
                dt { "Criado em" } dd { (when(&order.created_at)) }
                @if let Some(at) = &order.collected_at { dt { "Arquivos retirados em" } dd { (when(at)) } }
                @if let Some(at) = &order.printed_at { dt { "Impresso em" } dd { (when(at)) } }
                @if let Some(cents) = order.approved_amount_cents { dt { "Valor aprovado" } dd { (format_brl(cents)) } }
            }
        }
        section.card {
            h2 { "Arquivos e instruções (revisão " (order.revision) ")" }
            @for job in &order.jobs {
                article.job {
                    h3 { (job.title) }
                    p { strong { "Cópias: " } (job.copies) }
                    p.instructions { (job.instructions) }
                    p.muted { (job.file.name) " · " (size(job.file.bytes)) " · SHA-256 " code { (job.file.sha256[..12]) "…" } }
                    @if order.status != OrderStatus::Cancelled {
                        a.button.secondary href={"/api/print/v1/orders/" (order.id) "/files/" (job.file.id)} download { "Baixar arquivo" }
                    }
                }
            }
        }
        section.card #actions
            data-order-id=(order.id)
            data-etag=(etag)
            data-revision=(order.revision)
            data-quote-id=(quote.map(|q| q.id.as_str()).unwrap_or("")) {
            h2 { "Próximo passo" }
            @if let Some(q) = quote {
                div.quote {
                    p { strong { "Orçamento " (q.revision) ": " } (format_brl(q.amount_cents)) " · enviado em " (when(&q.submitted_at)) }
                    a.button.secondary href={"/api/print/v1/orders/" (order.id) "/quotes/" (q.id) "/file"} download { "Baixar orçamento" }
                    @if q.decision == QuoteDecision::Rejected {
                        div.notice.error { p { strong { "Orçamento rejeitado." } " Motivo: " (q.rejection_reason.as_deref().unwrap_or("—")) } }
                    }
                }
            }
            @match order.status {
                OrderStatus::Ready => {
                    form data-action="collect" {
                        label.check { input type="checkbox" name="checked" required; " Conferi todos os arquivos desta revisão" }
                        button type="submit" { "Arquivos retirados" }
                        (confirm("Confirma que retirou todos os arquivos desta revisão?", "Confirmar retirada"))
                    }
                }
                OrderStatus::FilesCollected | OrderStatus::QuoteRejected => {
                    form data-action="quote" {
                        label for="amount" { "Valor do orçamento" }
                        input #amount name="amount" inputmode="decimal" placeholder="0,00" autocomplete="off" required;
                        label for="quote-file" { "Arquivo do orçamento" }
                        input #quote-file type="file" name="file" accept=".pdf,.jpg,.jpeg,.png,.webp,application/pdf,image/jpeg,image/png,image/webp" required;
                        p.muted { "PDF, JPEG, PNG ou WebP, até 5 MB." }
                        button type="submit" {
                            @if order.status == OrderStatus::QuoteRejected { "Enviar novo orçamento" } @else { "Enviar orçamento" }
                        }
                        (confirm("Confirma o envio deste orçamento?", "Confirmar envio"))
                    }
                }
                OrderStatus::QuotePending => {
                    p.notice { "Aguardando aprovação do Financeiro." }
                }
                OrderStatus::QuoteApproved => {
                    p.notice.ok { "Orçamento aprovado." }
                    form data-action="printed" {
                        button type="submit" { "Marcar como impresso" }
                        (confirm("Confirma que a impressão foi concluída?", "Confirmar impressão"))
                    }
                }
                OrderStatus::Printed => {
                    p.notice.ok { "Pedido impresso. Ele entra na nota fiscal mensal da competência." }
                }
                OrderStatus::Cancelled => {
                    div.notice.error { p { strong { "Pedido cancelado." } " Motivo: " (order.cancellation_reason.as_deref().unwrap_or("—")) } }
                }
            }
            (recovery())
            p #message role="status" aria-live="polite" {}
        }
    }
}

fn not_found_page(state: &AppState, headers: &HeaderMap) -> Response {
    let session = state.session(headers);
    let body = html! {
        section.card {
            h1 { "Não encontrado" }
            p { "Este endereço não existe ou não está disponível para a gráfica." }
            a.button href="/orders" { "Ir para Pedidos" }
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
                p { "O envio da NF mensal ainda não foi habilitado no Incluir. Os pedidos continuam disponíveis em Pedidos." }
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
                "A NF mensal reúne os pedidos impressos na competência (mês no horário de Brasília) e só pode ser enviada depois do fim do mês."
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
            p.empty { "Nenhum pedido impresso nesta competência." }
        } @else {
            table.list {
                thead { tr { th { "Pedido" } th { "Impresso em" } th { "Valor aprovado" } } }
                tbody {
                    @for item in &close.items {
                        tr {
                            td data-label="Pedido" { a href={"/orders/" (item.order_id)} { (item.reference) } }
                            td data-label="Impresso em" { (when(&item.printed_at)) }
                            td data-label="Valor aprovado" { (format_brl(item.amount_cents)) }
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
            p { a.button.secondary href={"/api/print/v1/monthly-closes/" (competence) "/invoice"} download { "Baixar NF enviada" } " " span.muted { (document.name) } }
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
