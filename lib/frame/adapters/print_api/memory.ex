defmodule Frame.Adapters.PrintApi.Memory do
  @moduledoc """
  In-memory fake of the Incluir print-portal service API, for tests,
  examples and local runs. Backed by an `Agent`.

  It reproduces the upstream semantics the portal depends on — the same
  status codes, error codes and DTO shapes as the frozen contract:

    * order state machine (ready → files_collected → quote_pending →
      quote_approved/quote_rejected → printed; cancelled);
    * `ETag: "<id>:<version>"`, If-Match (412), missing preconditions
      (428), Idempotency-Key replay / conflict (409) keyed by intent;
    * keyset cursor pagination ordered by createdAt, id;
    * monthly closes per São Paulo competence, the virtual empty close and
      its `"month:<YYYY-MM>:0"` ETag, PERIOD_OPEN / EMPTY_CLOSE / INVALID_STATE.

  Staff-side actions that the portal never performs (seeding orders,
  approving/rejecting quotes, cancelling, deciding invoices) and failure
  injection are extra functions on this module, for tests and examples.

  Instrumented like the HTTP adapter: one `http.print_api.<operation>` span
  per call, `peer.service` = `"memory"`.
  """

  @behaviour Frame.Adapters.PrintApi

  require OpenTelemetry.Tracer, as: Tracer

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Domain.Competence
  alias Frame.Domain.Document
  alias OpenTelemetry.Span

  @enforce_keys [:agent]
  defstruct [:agent]

  @type t :: %__MODULE__{agent: pid()}

  @messages %{
    "NOT_FOUND" => "Recurso não encontrado.",
    "INVALID_REQUEST" => "Requisição inválida.",
    "INVALID_CURSOR" => "Cursor inválido.",
    "INVALID_COMPETENCE" => "Competência inválida. Use AAAA-MM.",
    "UNAUTHORIZED" => "Credencial inválida.",
    "INVALID_STATE" => "O pedido não está em um estado que permita esta operação.",
    "IDEMPOTENCY_CONFLICT" => "A chave de idempotência já foi usada para outra operação.",
    "VERSION_MISMATCH" => "O pedido foi atualizado. Consulte novamente antes de repetir.",
    "PRECONDITION_REQUIRED" => "Cabeçalhos If-Match e Idempotency-Key são obrigatórios.",
    "PERIOD_OPEN" =>
      "A competência ainda não terminou. A NF só pode ser enviada depois do fim do mês.",
    "EMPTY_CLOSE" => "Não há pedidos impressos nesta competência.",
    "FILE_TOO_LARGE" => "Arquivo acima de 5 MB.",
    "UNSUPPORTED_MEDIA_TYPE" => "Formato de arquivo não aceito.",
    "NOT_CONFIGURED" => "Serviço não configurado.",
    "INTERNAL" => "Erro interno."
  }

  @status %{
    "NOT_FOUND" => 404,
    "INVALID_REQUEST" => 400,
    "INVALID_CURSOR" => 400,
    "INVALID_COMPETENCE" => 400,
    "UNAUTHORIZED" => 401,
    "INVALID_STATE" => 409,
    "IDEMPOTENCY_CONFLICT" => 409,
    "PERIOD_OPEN" => 409,
    "EMPTY_CLOSE" => 409,
    "VERSION_MISMATCH" => 412,
    "PRECONDITION_REQUIRED" => 428,
    "FILE_TOO_LARGE" => 413,
    "UNSUPPORTED_MEDIA_TYPE" => 415,
    "NOT_CONFIGURED" => 503,
    "INTERNAL" => 500
  }

  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  # --- construction & staff-side helpers ---

  @doc """
  Starts an empty fake (the Agent is linked to the caller).
  Options: `:clock` (`(-> DateTime.t())`, default `DateTime.utc_now/0`).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          clock: clock,
          orders: %{},
          seq: 0,
          blobs: %{},
          closes: %{},
          idempotency: %{},
          failure: nil
        }
      end)

    %__MODULE__{agent: agent}
  end

  @typedoc "A job to seed: title, copies, instructions and the file."
  @type seed_job :: %{
          title: String.t(),
          copies: pos_integer(),
          instructions: String.t(),
          file_name: String.t(),
          bytes: binary()
        }

  @doc "Seeds a `ready` order (as if Financeiro approved it) and returns its DTO."
  @spec seed_order(t(), [seed_job()], keyword()) :: map()
  def seed_order(%__MODULE__{agent: agent}, jobs, opts \\ []) when jobs != [] do
    Agent.get_and_update(agent, fn state ->
      seq = state.seq + 1
      id = Keyword.get_lazy(opts, :id, &uuid/0)
      created_at = Keyword.get_lazy(opts, :created_at, fn -> state.clock.() end)

      {dto_jobs, blobs} =
        Enum.map_reduce(jobs, state.blobs, fn job, blobs ->
          file_id = uuid()
          mime = job[:mime] || mime_of(job.bytes)

          file = %{
            "id" => file_id,
            "name" => Document.sanitize_name(job.file_name),
            "mime" => mime,
            "bytes" => byte_size(job.bytes),
            "sha256" => sha256(job.bytes)
          }

          dto = %{
            "id" => uuid(),
            "title" => job.title,
            "copies" => job.copies,
            "instructions" => job.instructions,
            "file" => file
          }

          {dto, Map.put(blobs, file_id, {file["name"], mime, job.bytes})}
        end)

      [first | _] = dto_jobs
      extra = length(dto_jobs) - 1
      title = if extra > 0, do: "#{first["title"]} (+#{extra})", else: first["title"]

      order = %{
        "id" => id,
        "reference" => "IMP-" <> String.pad_leading(Integer.to_string(seq), 4, "0"),
        "title" => title,
        "revision" => 1,
        "version" => 1,
        "status" => "ready",
        "createdAt" => iso(created_at),
        "collectedAt" => nil,
        "printedAt" => nil,
        "approvedAmountCents" => nil,
        "jobs" => dto_jobs,
        "currentQuote" => nil,
        "cancellationReason" => nil
      }

      {order, %{state | seq: seq, blobs: blobs, orders: Map.put(state.orders, id, order)}}
    end)
  end

  @doc "Financeiro approves or rejects the current (pending) quote."
  @spec decide_quote(t(), String.t(), :approved | {:rejected, String.t()}) :: :ok | :error
  def decide_quote(%__MODULE__{agent: agent}, order_id, decision) do
    Agent.get_and_update(agent, fn state ->
      case state.orders[order_id] do
        %{"status" => "quote_pending", "currentQuote" => %{"decision" => "pending"}} = o ->
          order = apply_quote_decision(o, decision, iso(state.clock.()))
          {:ok, put_in(state.orders[order_id], order)}

        _ ->
          {:error, state}
      end
    end)
  end

  defp apply_quote_decision(%{"currentQuote" => q} = order, :approved, now) do
    quote = %{q | "decision" => "approved", "decidedAt" => now}

    bump(%{
      order
      | "status" => "quote_approved",
        "currentQuote" => quote,
        "approvedAmountCents" => q["amountCents"]
    })
  end

  defp apply_quote_decision(%{"currentQuote" => q} = order, {:rejected, reason}, now) do
    quote = %{q | "decision" => "rejected", "decidedAt" => now, "rejectionReason" => reason}

    bump(%{
      order
      | "status" => "quote_rejected",
        "currentQuote" => quote,
        "approvedAmountCents" => nil
    })
  end

  @doc "Financeiro cancels an order (not printed)."
  @spec cancel(t(), String.t(), String.t()) :: :ok | :error
  def cancel(%__MODULE__{agent: agent}, order_id, reason) do
    Agent.get_and_update(agent, fn state ->
      case state.orders[order_id] do
        %{"status" => status} = o when status not in ["printed", "cancelled"] ->
          order = bump(%{o | "status" => "cancelled", "cancellationReason" => reason})
          {:ok, put_in(state.orders[order_id], order)}

        _ ->
          {:error, state}
      end
    end)
  end

  @doc "Financeiro accepts or rejects the submitted invoice of a competence."
  @spec decide_invoice(t(), String.t(), :accepted | {:rejected, String.t()}) :: :ok | :error
  def decide_invoice(%__MODULE__{agent: agent}, competence, decision) do
    Agent.get_and_update(agent, fn state ->
      case state.closes[competence] do
        %{"state" => "submitted"} = close ->
          close = apply_invoice_decision(close, decision, iso(state.clock.()))
          {:ok, put_in(state.closes[competence], Map.update!(close, "version", &(&1 + 1)))}

        _ ->
          {:error, state}
      end
    end)
  end

  defp apply_invoice_decision(close, :accepted, now),
    do: %{close | "state" => "accepted", "acceptedAt" => now}

  defp apply_invoice_decision(close, {:rejected, reason}, _now),
    do: %{close | "state" => "rejected", "rejectionReason" => reason}

  @doc """
  Injects a failure for every following call: `:unavailable` (transport
  error), `:unauthorized` (token refused, 401), `:not_configured` (503), or
  `nil` to heal.
  """
  @spec fail_with(t(), nil | :unavailable | :unauthorized | :not_configured) :: :ok
  def fail_with(%__MODULE__{agent: agent}, failure),
    do: Agent.update(agent, &%{&1 | failure: failure})

  # --- the port ---

  @impl true
  def list_orders(api, query) do
    call(api, "listOrders", fn state ->
      status = query[:status]

      case decode_cursor(query[:cursor], status) do
        {:ok, after_key} ->
          {ok(200, list_page(state, status, query[:limit] || 20, after_key)), state}

        :error ->
          {error("INVALID_CURSOR"), state}
      end
    end)
  end

  defp list_page(state, status, limit, after_key) do
    sorted =
      state.orders
      |> Map.values()
      |> Enum.filter(&(status == nil or &1["status"] == status))
      |> Enum.sort_by(&{&1["createdAt"], &1["id"]})
      |> Enum.drop_while(&(after_key != nil and {&1["createdAt"], &1["id"]} <= after_key))

    {page, rest} = Enum.split(sorted, limit)

    next =
      case {rest, List.last(page)} do
        {[], _} -> nil
        {_, last} -> encode_cursor(last, status)
      end

    %{"items" => Enum.map(page, &summary/1), "nextCursor" => next}
  end

  @impl true
  def get_order(api, id) do
    call(api, "getOrder", fn state ->
      case find(state, id) do
        nil -> {error("NOT_FOUND"), state}
        order -> {ok(200, %{"order" => order}, etag(order)), state}
      end
    end)
  end

  @impl true
  def collect(api, id, %{revision: revision}, pre) do
    order_command(api, "collectFiles", id, pre, %{"revision" => revision}, 200, fn order, now ->
      cond do
        order["status"] != "ready" -> {:error, "INVALID_STATE"}
        order["revision"] != revision -> {:error, "VERSION_MISMATCH"}
        true -> {:ok, %{order | "status" => "files_collected", "collectedAt" => now}, []}
      end
    end)
  end

  @impl true
  def submit_quote(api, id, input, pre) do
    fields = %{
      "amountCents" => input.amount_cents,
      "orderRevision" => input.order_revision,
      "fileSha256" => sha256(input.file.bytes)
    }

    order_command(api, "submitQuote", id, pre, fields, 201, &quote_transition(&1, input, &2))
  end

  defp quote_transition(order, input, now) do
    with {:ok, mime} <- document(input.file.bytes),
         :ok <- quotable(order, input.order_revision) do
      quote_id = uuid()
      name = Document.sanitize_name(input.file.name)
      revision = if order["currentQuote"], do: order["currentQuote"]["revision"] + 1, else: 1

      quote = %{
        "id" => quote_id,
        "revision" => revision,
        "orderRevision" => order["revision"],
        "amountCents" => input.amount_cents,
        "currency" => "BRL",
        "document" => %{
          "id" => quote_id,
          "name" => name,
          "mime" => mime,
          "bytes" => byte_size(input.file.bytes),
          "sha256" => sha256(input.file.bytes)
        },
        "decision" => "pending",
        "rejectionReason" => nil,
        "submittedAt" => now,
        "decidedAt" => nil
      }

      blob = {quote_id, {name, mime, input.file.bytes}}
      {:ok, %{order | "status" => "quote_pending", "currentQuote" => quote}, [blob]}
    end
  end

  @impl true
  def mark_printed(api, id, %{revision: revision, quote_id: quote_id}, pre) do
    fields = %{"revision" => revision, "quoteId" => quote_id}

    order_command(api, "markPrinted", id, pre, fields, 200, fn order, now ->
      quote = order["currentQuote"]

      cond do
        order["status"] != "quote_approved" or quote["decision"] != "approved" ->
          {:error, "INVALID_STATE"}

        order["revision"] != revision or quote["id"] != quote_id ->
          {:error, "VERSION_MISMATCH"}

        true ->
          {:ok,
           %{
             order
             | "status" => "printed",
               "printedAt" => now,
               "approvedAmountCents" => quote["amountCents"]
           }, []}
      end
    end)
  end

  @impl true
  def get_close(api, competence) do
    call(api, "getMonthlyClose", fn state ->
      case Competence.parse(competence) do
        {:ok, c} ->
          {ok(200, %{"close" => close_view(state, c)}, close_etag(state, competence)), state}

        :error ->
          {error("INVALID_COMPETENCE"), state}
      end
    end)
  end

  @impl true
  def submit_invoice(api, competence, input, pre) do
    call(api, "submitInvoice", &invoice_command(&1, competence, input, pre))
  end

  defp invoice_command(state, competence, input, pre) do
    with {:ok, c} <- competence_or_error(competence),
         {:ok, key} <- preconditions(pre),
         {:ok, mime} <- document(input.file.bytes) do
      intent =
        {"/monthly-closes/#{competence}/invoice", pre.if_match, input.declared_total_cents,
         sha256(input.file.bytes)}

      idempotent(state, key, intent, fn ->
        submit_invoice_now(state, c, competence, pre.if_match, input, mime)
      end)
    else
      {:error, code} -> {error(code), state}
    end
  end

  @impl true
  def download(api, target, acc, sink) do
    result =
      call(api, "downloadDocument", fn state ->
        case blob_for(state, target) do
          nil -> {error("NOT_FOUND"), state}
          blob -> {{:blob, blob}, state}
        end
      end)

    case result do
      {:blob, {name, mime, bytes}} ->
        headers = %{
          "content-type" => mime,
          "content-length" => Integer.to_string(byte_size(bytes)),
          "content-disposition" => Document.content_disposition(name)
        }

        acc = sink.({:head, headers}, acc)
        {:streamed, sink.({:data, bytes}, acc)}

      other ->
        other
    end
  end

  # --- order commands ---

  defp order_command(api, operation, id, pre, fields, success, transition) do
    call(api, operation, &run_order_command(&1, {operation, id, pre, fields}, success, transition))
  end

  defp run_order_command(state, {operation, id, pre, fields}, success, transition) do
    with %{} <- find(state, id) || {:error, "NOT_FOUND"},
         {:ok, key} <- preconditions(pre) do
      intent = {operation, id, pre.if_match, fields}

      idempotent(state, key, intent, fn ->
        apply_order_command(state, id, pre.if_match, success, transition)
      end)
    else
      {:error, code} -> {error(code), state}
    end
  end

  defp apply_order_command(state, id, if_match, success, transition) do
    order = state.orders[id]
    now = iso(state.clock.())

    with :ok <- match_etag(if_match, etag(order)),
         {:ok, updated, blobs} <- transition.(order, now) do
      updated = bump(updated)

      state = %{
        state
        | orders: Map.put(state.orders, id, updated),
          blobs: Map.merge(state.blobs, Map.new(blobs))
      }

      state = if updated["status"] == "printed", do: bill(state, updated), else: state
      {:ok, ok(success, %{"order" => updated}, etag(updated)), state}
    else
      {:error, code} -> {:error, error(code), state}
    end
  end

  defp quotable(%{"status" => status} = order, order_revision)
       when status in ["files_collected", "quote_rejected"] do
    if order["revision"] == order_revision, do: :ok, else: {:error, "VERSION_MISMATCH"}
  end

  defp quotable(_order, _revision), do: {:error, "INVALID_STATE"}

  # A printed order joins the close of its São Paulo competence.
  defp bill(state, order) do
    {:ok, printed_at, 0} = DateTime.from_iso8601(order["printedAt"])
    competence = printed_at |> Competence.containing() |> Competence.to_string()

    item = %{
      "orderId" => order["id"],
      "reference" => order["reference"],
      "quoteId" => order["currentQuote"]["id"],
      "amountCents" => order["approvedAmountCents"],
      "printedAt" => order["printedAt"]
    }

    close =
      Map.get(state.closes, competence) ||
        %{
          "id" => uuid(),
          "competence" => competence,
          "version" => 0,
          "state" => "open",
          "items" => [],
          "declaredTotalCents" => nil,
          "document" => nil,
          "rejectionReason" => nil,
          "submittedAt" => nil,
          "acceptedAt" => nil
        }

    close = %{close | "items" => close["items"] ++ [item], "version" => close["version"] + 1}
    put_in(state.closes[competence], close)
  end

  # --- invoices ---

  defp submit_invoice_now(state, c, competence, if_match, input, mime) do
    stored = state.closes[competence]
    view = close_view(state, c)

    cond do
      stored == nil and String.trim(if_match) == ~s("month:#{competence}:0") ->
        {:error, error("EMPTY_CLOSE"), state}

      stored == nil or if_match != close_etag(state, competence) ->
        {:error, error("VERSION_MISMATCH"), state}

      not view["periodClosed"] ->
        {:error, error("PERIOD_OPEN"), state}

      stored["state"] in ["submitted", "accepted"] ->
        {:error, error("INVALID_STATE"), state}

      true ->
        doc_id = uuid()
        name = Document.sanitize_name(input.file.name)

        close = %{
          stored
          | "state" => "submitted",
            "version" => stored["version"] + 1,
            "declaredTotalCents" => input.declared_total_cents,
            "rejectionReason" => nil,
            "submittedAt" => iso(state.clock.()),
            "document" => %{
              "id" => doc_id,
              "name" => name,
              "mime" => mime,
              "bytes" => byte_size(input.file.bytes),
              "sha256" => sha256(input.file.bytes)
            }
        }

        state = %{
          state
          | closes: Map.put(state.closes, competence, close),
            blobs: Map.put(state.blobs, doc_id, {name, mime, input.file.bytes})
        }

        {:ok, ok(201, %{"close" => close_view(state, c)}, close_etag(state, competence)), state}
    end
  end

  defp close_view(state, %Competence{} = c) do
    key = Competence.to_string(c)
    period_closed = not Competence.open?(c, state.clock.())

    case state.closes[key] do
      nil ->
        %{
          "id" => nil,
          "competence" => key,
          "version" => 0,
          "state" => "open",
          "periodClosed" => period_closed,
          "items" => [],
          "expectedTotalCents" => 0,
          "declaredTotalCents" => nil,
          "document" => nil,
          "rejectionReason" => nil,
          "submittedAt" => nil,
          "acceptedAt" => nil
        }

      close ->
        close
        |> Map.put("periodClosed", period_closed)
        |> Map.put("expectedTotalCents", Enum.sum_by(close["items"], & &1["amountCents"]))
    end
  end

  defp close_etag(state, competence) do
    case state.closes[competence] do
      nil -> ~s("month:#{competence}:0")
      close -> ~s("#{close["id"]}:#{close["version"]}")
    end
  end

  defp competence_or_error(competence) do
    case Competence.parse(competence) do
      {:ok, c} -> {:ok, c}
      :error -> {:error, "INVALID_COMPETENCE"}
    end
  end

  # --- shared command machinery ---

  defp preconditions(%{if_match: if_match, idempotency_key: key})
       when is_binary(if_match) and is_binary(key) do
    if Regex.match?(@uuid, key), do: {:ok, String.downcase(key)}, else: {:error, "INVALID_REQUEST"}
  end

  defp preconditions(_pre), do: {:error, "PRECONDITION_REQUIRED"}

  # Same key + same intent replays the stored answer (even after the
  # version advanced); same key + other intent conflicts. Failures do not
  # consume the key.
  defp idempotent(state, key, intent, run) do
    case state.idempotency[key] do
      {^intent, response} ->
        {%{response | replayed: true}, state}

      {_other, _response} ->
        {error("IDEMPOTENCY_CONFLICT"), state}

      nil ->
        case run.() do
          {:ok, response, state} -> {response, put_in(state.idempotency[key], {intent, response})}
          {:error, response, state} -> {response, state}
        end
    end
  end

  defp match_etag(if_match, current) do
    if String.trim(if_match) == current, do: :ok, else: {:error, "VERSION_MISMATCH"}
  end

  defp document(bytes) do
    case Document.validate(bytes) do
      {:ok, mime} -> {:ok, mime}
      {:error, :empty} -> {:error, "INVALID_REQUEST"}
      {:error, :too_large} -> {:error, "FILE_TOO_LARGE"}
      {:error, :unsupported_media_type} -> {:error, "UNSUPPORTED_MEDIA_TYPE"}
    end
  end

  defp blob_for(state, {:order_file, order_id, file_id}) do
    with %{} = order <- find(state, order_id),
         true <- Enum.any?(order["jobs"], &(&1["file"]["id"] == file_id)) do
      state.blobs[file_id]
    else
      _ -> nil
    end
  end

  defp blob_for(state, {:quote_file, order_id, quote_id}) do
    case find(state, order_id) do
      %{"currentQuote" => %{"id" => ^quote_id}} -> state.blobs[quote_id]
      _ -> nil
    end
  end

  defp blob_for(state, {:invoice_file, competence}) do
    case state.closes[competence] do
      %{"document" => %{"id" => doc_id}} -> state.blobs[doc_id]
      _ -> nil
    end
  end

  defp find(state, id) when is_binary(id), do: state.orders[id]
  defp find(_state, _id), do: nil

  defp bump(order), do: Map.update!(order, "version", &(&1 + 1))

  defp summary(order),
    do: Map.drop(order, ["jobs", "currentQuote", "cancellationReason"])

  defp etag(order), do: ~s("#{order["id"]}:#{order["version"]}")

  defp encode_cursor(order, status),
    do: Base.url_encode64(JSON.encode!([order["createdAt"], order["id"], status]), padding: false)

  defp decode_cursor(nil, _status), do: {:ok, nil}

  defp decode_cursor(cursor, status) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         {:ok, [created_at, id, ^status]} <- JSON.decode(raw) do
      {:ok, {created_at, id}}
    else
      _ -> :error
    end
  end

  defp ok(status, body, etag \\ nil), do: %Response{status: status, body: body, etag: etag}

  defp error(code) do
    body = %{"error" => %{"code" => code, "message" => @messages[code], "requestId" => ""}}
    %Response{status: @status[code], body: body}
  end

  # One span per call; injected failures short-circuit before any state change.
  defp call(%__MODULE__{agent: agent}, operation, fun) do
    attributes = %{"peer.service": "memory", "url.template": operation}

    Tracer.with_span "http.print_api." <> operation, %{kind: :client, attributes: attributes} do
      span = Tracer.current_span_ctx()

      result =
        Agent.get_and_update(agent, fn state ->
          case state.failure do
            nil -> fun.(state)
            :unavailable -> {{:error, :unavailable}, state}
            :unauthorized -> {error("UNAUTHORIZED"), state}
            :not_configured -> {error("NOT_CONFIGURED"), state}
          end
        end)

      case result do
        %Response{} = response ->
          Span.set_attribute(span, :"http.response.status_code", response.status)
          Span.set_status(span, OpenTelemetry.status(:ok))
          {:ok, response}

        {:error, :unavailable} = error ->
          Span.set_status(span, OpenTelemetry.status(:error, "upstream transport"))
          error

        other ->
          Span.set_status(span, OpenTelemetry.status(:ok))
          other
      end
    end
  end

  defp mime_of(bytes) do
    case Document.detect_mime(bytes) do
      {:ok, mime} -> mime
      :error -> "application/octet-stream"
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp iso(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
  end
end
