defmodule Frame.Http.Pages do
  @moduledoc """
  Server-rendered HTML for the supplier (spec §7): `/login`, `/orders`,
  `/orders/:id`, `/invoices`, plus the form posts behind their buttons.

  Every form post is a browser command: exact `Origin`, the session's CSRF
  token (`_csrf` field), and the order/close ETag + an Idempotency-Key
  rendered into the form, so a double click replays instead of repeating
  and a stale page gets "Pedido atualizado; confira novamente" (412).
  When the upstream does not answer, nothing is reported as done: the page
  offers "Consultar novamente" and a repeat with the *same* key.
  """

  import Plug.Conn

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Adapters.SessionStore
  alias Frame.Domain.Close
  alias Frame.Domain.Competence
  alias Frame.Domain.Document
  alias Frame.Domain.Money
  alias Frame.Domain.Order
  alias Frame.Domain.Requests
  alias Frame.Errors.PortalError
  alias Frame.Http.Multipart
  alias Frame.Http.Security
  alias Frame.Http.Views
  alias Frame.UseCases

  @form_limit 16_384

  @doc "Dispatches the HTML routes (path segments)."
  @spec call(Plug.Conn.t(), map(), [String.t()]) :: Plug.Conn.t()
  def call(conn, deps, path), do: route(conn, deps, conn.method, path)

  defp route(conn, deps, "GET", []),
    do: redirect(conn, if(signed_in?(conn, deps), do: "/orders", else: "/login"))

  defp route(conn, deps, "GET", ["login"]), do: login_page(conn, deps)
  defp route(conn, deps, "POST", ["login"]), do: login(conn, deps)
  defp route(conn, deps, "POST", ["logout"]), do: logout(conn, deps)
  defp route(conn, deps, "GET", ["orders"]), do: guarded(conn, deps, &orders/3)
  defp route(conn, deps, "GET", ["orders", id]), do: guarded(conn, deps, &order(&1, &2, &3, id))

  defp route(conn, deps, "POST", ["orders", id, action])
       when action in ["collected", "quotes", "printed"],
       do: command(conn, deps, &order_command(&1, &2, &3, id, action))

  defp route(conn, deps, "GET", ["invoices"]), do: guarded(conn, deps, &invoices/3)

  defp route(conn, deps, "POST", ["invoices", competence]),
    do: command(conn, deps, &invoice_command(&1, &2, &3, competence))

  defp route(conn, deps, method, path) do
    known =
      path in [[], ["login"], ["logout"], ["orders"], ["invoices"]] or match?(["orders", _], path)

    if known and method not in ["GET", "POST"],
      do:
        conn
        |> put_resp_header("allow", "GET, POST")
        |> page(405, Views.not_found(conn_nav(conn, deps))),
      else: not_found(conn, deps)
  end

  # --- login / logout ---

  defp login_page(conn, deps) do
    if signed_in?(conn, deps) do
      redirect(conn, "/orders")
    else
      {conn, pre} = ensure_pre_session(conn, deps)
      page(conn, 200, Views.login(%{csrf: pre.csrf_token, error: nil}))
    end
  end

  defp login(conn, deps) do
    pre_id = Security.cookie(conn, Security.pre_session_cookie())

    with true <- Security.same_origin?(conn, deps.portal_origin),
         {:ok, conn, form} <- form(conn),
         {:ok, pre} <- fetch_pre(deps, pre_id),
         true <- Security.csrf_valid?(form["_csrf"], pre) do
      input = %{
        password: form["password"] || "",
        client_ip: Security.client_ip(conn, deps.trusted_proxies),
        revoke: Enum.reject([pre_id, Security.cookie(conn, Security.session_cookie())], &is_nil/1)
      }

      case UseCases.LogIn.log_in(deps, input) do
        {:ok, session} ->
          conn
          |> Security.put_cookie(Security.session_cookie(), session.id)
          |> Security.drop_cookie(Security.pre_session_cookie())
          |> redirect("/orders")

        {:error, %PortalError{} = error} ->
          login_failed(conn, pre, error)
      end
    else
      _ -> forbidden(conn, deps)
    end
  end

  defp login_failed(conn, pre, error) do
    conn =
      if error.retry_after,
        do: put_resp_header(conn, "retry-after", "#{error.retry_after}"),
        else: conn

    page(conn, error.status, Views.login(%{csrf: pre.csrf_token, error: error.reason}))
  end

  defp logout(conn, deps) do
    with true <- Security.same_origin?(conn, deps.portal_origin),
         {:ok, conn, form} <- form(conn) do
      log_out(conn, deps, form)
    else
      _ -> forbidden(conn, deps)
    end
  end

  defp log_out(conn, deps, form) do
    case Security.current_session(conn, deps.session_store) do
      {:ok, session} ->
        if Security.csrf_valid?(form["_csrf"], session),
          do: end_session(conn, deps, session),
          else: forbidden(conn, deps)

      :error ->
        conn |> Security.drop_cookie(Security.session_cookie()) |> redirect("/login")
    end
  end

  defp end_session(conn, deps, session) do
    UseCases.LogOut.log_out(deps, session.id)
    conn |> Security.drop_cookie(Security.session_cookie()) |> redirect("/login")
  end

  # --- orders ---

  defp orders(conn, deps, session) do
    conn = fetch_query_params(conn)
    params = conn.query_params

    {query, back} =
      case Requests.list_query(Map.take(params, ["status", "cursor"])) do
        {:ok, query} -> {query, back_stack(params["voltar"])}
        :error -> {%{}, []}
      end

    result =
      case UseCases.ListOrders.list_orders(deps, Map.put(query, :limit, 20)) do
        {:ok, %Response{status: 200, body: body}} -> {:ok, body["items"], body["nextCursor"]}
        {:ok, %Response{body: %{"error" => %{"code" => "INVALID_CURSOR"}}}} -> :invalid_cursor
        _ -> :unavailable
      end

    assigns = %{
      nav: nav(session, :orders),
      result: result,
      status: query[:status],
      cursor: query[:cursor],
      back: back
    }

    page(conn, if(result == :unavailable, do: 503, else: 200), Views.orders(assigns))
  end

  defp back_stack(nil), do: []

  defp back_stack(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.take(-20)
    |> Enum.filter(&(&1 == "-" or match?({:ok, _}, Requests.list_query(%{"cursor" => &1}))))
  end

  defp back_stack(_value), do: []

  defp order(conn, deps, session, id, notice \\ nil, status \\ 200, form \\ %{}) do
    with {:ok, id} <- Requests.uuid(id),
         {:ok, %Response{status: 200, body: %{"order" => order}}} <-
           UseCases.GetOrder.get_order(deps, id) do
      conn = fetch_query_params(conn)
      notice = notice || done_notice(conn.query_params["feito"])

      page(
        conn,
        status,
        Views.order(%{
          nav: nav(session, :orders),
          order: order,
          etag: Order.etag(order),
          notice: notice,
          key: form[:key] || idempotency_key(conn.query_params["chave"]),
          amount: form[:amount] || ""
        })
      )
    else
      {:ok, %Response{status: 404}} -> not_found(conn, deps)
      :error -> not_found(conn, deps)
      _ -> unavailable(conn, session, "/orders/#{id}")
    end
  end

  defp done_notice("collected"), do: {:ok, "Retirada confirmada."}
  defp done_notice("quote"), do: {:ok, "Orçamento enviado. Aguardando aprovação do Financeiro."}
  defp done_notice("printed"), do: {:ok, "Impressão confirmada."}
  defp done_notice(_), do: nil

  defp order_command(conn, deps, session, id, action) do
    with {:ok, id} <- Requests.uuid(id),
         {:ok, conn, form, file} <- read_command_form(conn, action),
         true <- Security.csrf_valid?(form["_csrf"], session) || :csrf,
         {:ok, pre} <- form_preconditions(form) do
      result = run_order_command(deps, id, action, form, file, pre)
      after_command(conn, deps, session, id, action, form, pre, result)
    else
      :csrf ->
        forbidden(conn, deps)

      :error ->
        not_found(conn, deps)

      {:error, conn, :too_large} ->
        order(conn, deps, session, id, {:error, "O arquivo passa de 5 MB."}, 413)

      _ ->
        order(
          conn,
          deps,
          session,
          id,
          {:error, "Formulário inválido. Confira os campos e tente novamente."},
          400
        )
    end
  end

  defp read_command_form(conn, "quotes") do
    case Multipart.read(conn, Document.max_body_bytes()) do
      {:ok, conn, fields, file} -> {:ok, conn, fields, file}
      {:error, conn, reason} -> {:error, conn, reason}
    end
  end

  defp read_command_form(conn, _action) do
    with {:ok, conn, form} <- form(conn), do: {:ok, conn, form, nil}
  end

  defp run_order_command(deps, id, "collected", form, _file, pre) do
    with {:ok, revision} <- Requests.revision_string(form["revision"]),
         "on" <- form["conferi"] || :unchecked do
      UseCases.CollectFiles.collect_files(deps, id, %{revision: revision}, pre)
    else
      :unchecked ->
        {:form_error, "Marque “Conferi todos os arquivos desta revisão” para confirmar a retirada."}

      _ ->
        {:form_error, "Formulário inválido."}
    end
  end

  defp run_order_command(deps, id, "printed", form, _file, pre) do
    with {:ok, revision} <- Requests.revision_string(form["revision"]),
         {:ok, quote_id} <- Requests.uuid(form["quote_id"]) do
      UseCases.MarkPrinted.mark_printed(deps, id, %{revision: revision, quote_id: quote_id}, pre)
    else
      _ -> {:form_error, "Formulário inválido."}
    end
  end

  defp run_order_command(deps, id, "quotes", form, file, pre) do
    with {:ok, revision} <- Requests.revision_string(form["revision"]),
         {:amount, {:ok, cents}} <- {:amount, Money.parse_brl(form["valor"])},
         {:file, %{bytes: bytes}} when bytes != "" <- {:file, file} do
      input = %{amount_cents: cents, order_revision: revision, file: file}
      UseCases.SubmitQuote.submit_quote(deps, id, input, pre)
    else
      {:amount, _} -> {:form_error, "Informe o valor do orçamento em reais, por exemplo 459,90."}
      {:file, _} -> {:form_error, "Escolha o arquivo do orçamento (PDF, JPEG, PNG ou WebP)."}
      _ -> {:form_error, "Formulário inválido."}
    end
  end

  @done %{"collected" => "collected", "quotes" => "quote", "printed" => "printed"}

  defp after_command(conn, deps, session, id, action, form, pre, result) do
    keep = %{key: pre.idempotency_key, amount: form["valor"]}

    case result do
      {:ok, %Response{status: status}} when status in 200..299 ->
        redirect(conn, "/orders/#{id}?feito=#{@done[action]}")

      {:ok, %Response{status: 404}} ->
        not_found(conn, deps)

      {:ok, %Response{status: status, body: %{"error" => %{"code" => code}}}} ->
        fresh = if code in ["OPERATION_IN_PROGRESS"], do: keep, else: %{keep | key: nil}
        order(conn, deps, session, id, {:error, upstream_message(code)}, status, fresh)

      {:form_error, message} ->
        order(conn, deps, session, id, {:error, message}, 400, keep)

      {:error, %PortalError{reason: :upstream_unavailable}} ->
        retry(conn, session, %{
          action: "/orders/#{id}/#{action}",
          back: "/orders/#{id}?chave=#{pre.idempotency_key}",
          fields: if(action == "quotes", do: nil, else: retry_fields(form, session))
        })

      {:error, %PortalError{} = error} ->
        order(conn, deps, session, id, {:error, error.message}, error.status, keep)
    end
  end

  defp retry_fields(form, session) do
    form
    |> Map.take(["revision", "quote_id", "if_match", "idempotency_key", "conferi"])
    |> Map.put("_csrf", session.csrf_token)
  end

  @messages %{
    "VERSION_MISMATCH" => "Pedido atualizado; confira novamente.",
    "INVALID_STATE" =>
      "Esta ação não está mais disponível para este pedido. Confira a situação atual.",
    "IDEMPOTENCY_CONFLICT" =>
      "Esta confirmação já foi usada para outra operação. Confira o pedido.",
    "OPERATION_IN_PROGRESS" =>
      "A operação ainda está em andamento. Consulte novamente em instantes.",
    "FILE_TOO_LARGE" => "O arquivo passa de 5 MB.",
    "UNSUPPORTED_MEDIA_TYPE" => "Formato não aceito. Envie PDF, JPEG, PNG ou WebP.",
    "PRECONDITION_REQUIRED" => "Recarregue a página e tente novamente.",
    "RATE_LIMITED" => "Muitas operações seguidas. Aguarde um pouco e tente novamente.",
    "PERIOD_OPEN" =>
      "A competência ainda não terminou. A NF só pode ser enviada depois do fim do mês.",
    "EMPTY_CLOSE" => "Não há pedidos impressos nesta competência.",
    "INVALID_REQUEST" => "Dados inválidos. Confira os campos e tente novamente.",
    "INVALID_COMPETENCE" => "Competência inválida."
  }

  defp upstream_message(code), do: Map.get(@messages, code, "Não foi possível concluir a operação.")

  # --- invoices ---

  defp invoices(conn, deps, session, notice \\ nil, status \\ 200, form \\ %{}) do
    conn = fetch_query_params(conn)
    current = Competence.containing(deps.clock.())
    competence = selected_competence(conn.query_params["competencia"], current)
    result = monthly_close(deps, Competence.to_string(competence))
    notice = notice || invoice_notice(conn.query_params["feito"])

    page(
      conn,
      if(result == :unavailable, do: 503, else: status),
      Views.invoices(%{
        nav: nav(session, :invoices),
        competence: competence,
        competences: Competence.recent(current, 12),
        result: result,
        submission: submission(result),
        notice: notice,
        key: form[:key] || idempotency_key(conn.query_params["chave"]),
        amount: form[:amount] || ""
      })
    )
  end

  defp selected_competence(value, current) do
    case Competence.parse(value) do
      {:ok, c} -> c
      :error -> Competence.previous(current)
    end
  end

  defp monthly_close(deps, key) do
    case UseCases.GetMonthlyClose.get_monthly_close(deps, key) do
      {:ok, %Response{status: 200, body: %{"close" => close}}} -> {:ok, close}
      {:ok, %Response{status: 404}} -> :not_available
      _ -> :unavailable
    end
  end

  defp invoice_notice("nf"), do: {:ok, "NF enviada. Aguardando conferência do Financeiro."}
  defp invoice_notice(_), do: nil

  defp submission({:ok, close}), do: Close.submission(close)
  defp submission(_result), do: nil

  defp invoice_command(conn, deps, session, competence) do
    with {:ok, c} <- Competence.parse(competence),
         {:ok, conn, form, file} <- read_command_form(conn, "quotes"),
         true <- Security.csrf_valid?(form["_csrf"], session) || :csrf,
         {:ok, pre} <- form_preconditions(form) do
      key = Competence.to_string(c)
      conn = %{conn | query_params: %{"competencia" => key}}
      keep = %{key: pre.idempotency_key, amount: form["valor"]}

      result =
        with {:amount, {:ok, cents}} <- {:amount, Money.parse_brl(form["valor"])},
             {:file, %{bytes: bytes}} when bytes != "" <- {:file, file} do
          UseCases.SubmitInvoice.submit_invoice(
            deps,
            key,
            %{declared_total_cents: cents, file: file},
            pre
          )
        else
          {:amount, _} -> {:form_error, "Informe o valor total da NF em reais, por exemplo 579,00."}
          {:file, _} -> {:form_error, "Escolha o arquivo da NF (PDF, JPEG, PNG ou WebP)."}
        end

      case result do
        {:ok, %Response{status: s}} when s in 200..299 ->
          redirect(conn, "/invoices?competencia=#{key}&feito=nf")

        {:ok, %Response{status: s, body: %{"error" => %{"code" => code}}}} ->
          invoices(conn, deps, session, {:error, upstream_message(code)}, s, %{keep | key: nil})

        {:form_error, message} ->
          invoices(conn, deps, session, {:error, message}, 400, keep)

        {:error, %PortalError{reason: :upstream_unavailable}} ->
          retry(conn, session, %{
            action: nil,
            back: "/invoices?competencia=#{key}&chave=#{pre.idempotency_key}",
            fields: nil
          })

        {:error, %PortalError{} = error} ->
          invoices(conn, deps, session, {:error, error.message}, error.status, keep)
      end
    else
      :csrf ->
        forbidden(conn, deps)

      :error ->
        not_found(conn, deps)

      {:error, conn, :too_large} ->
        invoices(conn, deps, session, {:error, "O arquivo passa de 5 MB."}, 413)

      _ ->
        invoices(
          conn,
          deps,
          session,
          {:error, "Formulário inválido. Confira os campos e tente novamente."},
          400
        )
    end
  end

  # --- shared ---

  defp guarded(conn, deps, fun) do
    case Security.current_session(conn, deps.session_store) do
      {:ok, session} -> fun.(conn, deps, session)
      :error -> redirect(conn, "/login")
    end
  end

  # A browser command: session (else back to login, nothing done), exact
  # Origin; the CSRF field is checked by the handler after reading the body.
  defp command(conn, deps, fun) do
    case Security.current_session(conn, deps.session_store) do
      {:ok, session} ->
        if Security.same_origin?(conn, deps.portal_origin),
          do: fun.(conn, deps, session),
          else: forbidden(conn, deps)

      :error ->
        redirect(conn, "/login")
    end
  end

  # A form without usable ETag/key is an invalid form (400), never a 404.
  defp form_preconditions(form) do
    with {:ok, if_match} <- Requests.if_match(form["if_match"]),
         {:ok, key} <- Requests.uuid(form["idempotency_key"]) do
      {:ok, %{if_match: if_match, idempotency_key: key}}
    else
      :error -> {:error, :invalid_form}
    end
  end

  defp form(conn) do
    with ["application/x-www-form-urlencoded" <> _] <- get_req_header(conn, "content-type"),
         {:ok, raw, conn} <- read_body(conn, length: @form_limit),
         true <- String.valid?(raw) do
      {:ok, conn, URI.decode_query(raw)}
    else
      _ -> :error
    end
  rescue
    _ in [ArgumentError, Plug.BadRequestError] -> :error
  end

  defp ensure_pre_session(conn, deps) do
    input = %{session_id: nil, pre_session_id: Security.cookie(conn, Security.pre_session_cookie())}
    {:ok, {:anonymous, pre, status}} = UseCases.EstablishSession.establish_session(deps, input)

    conn =
      if status == :created,
        do: Security.put_cookie(conn, Security.pre_session_cookie(), pre.id),
        else: conn

    {conn, pre}
  end

  defp fetch_pre(_deps, nil), do: :error
  defp fetch_pre(deps, id), do: SessionStore.fetch(deps.session_store, id, :pre)

  defp signed_in?(conn, deps),
    do: match?({:ok, _}, Security.current_session(conn, deps.session_store))

  defp nav(session, current), do: %{csrf: session.csrf_token, current: current}

  defp conn_nav(conn, deps) do
    case Security.current_session(conn, deps.session_store) do
      {:ok, session} -> nav(session, nil)
      :error -> nil
    end
  end

  defp idempotency_key(value) do
    case Requests.uuid(value) do
      {:ok, key} -> key
      :error -> uuid4()
    end
  end

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
  end

  defp retry(conn, session, assigns),
    do: page(conn, 503, Views.retry(Map.put(assigns, :nav, nav(session, nil))))

  defp unavailable(conn, session, back),
    do:
      page(conn, 503, Views.retry(%{nav: nav(session, nil), action: nil, back: back, fields: nil}))

  defp not_found(conn, deps), do: page(conn, 404, Views.not_found(conn_nav(conn, deps)))

  defp forbidden(conn, _deps), do: page(conn, 403, Views.forbidden())

  defp redirect(conn, to) do
    status = if conn.method == "GET", do: 302, else: 303
    conn |> put_resp_header("location", to) |> send_resp(status, "")
  end

  defp page(conn, status, html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end
end
