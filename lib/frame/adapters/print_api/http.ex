defmodule Frame.Adapters.PrintApi.Http do
  @moduledoc """
  PrintApi over HTTP to the Incluir Hono API (`/api/print-portal/v1` and
  the batch contract `/api/print-portal/v2`), with Finch.

  Security properties (spec §5):

    * The origin is fixed at construction (configuration, never a request
      parameter); paths are built only from validated ids.
    * The bearer service token is sent only to that origin, and never shows
      up in `inspect/1`, spans or logs.
    * Redirects are never followed (Finch does not follow them; a 3xx is
      treated as an unavailable upstream), so the token cannot be
      forwarded to a redirect target.
    * Every request has a total deadline; JSON responses are capped at
      `@max_json_bytes`, downloads at `@max_download_bytes`.
    * 2xx bodies are validated against the frozen contract
      (`Frame.Domain.Contract`); off-contract answers are `:unavailable`.

  Spans: one `http.print_api.<operation>` span per call (adapters emit spans
  only — they do not log), with method, route template and status code.
  """

  @behaviour Frame.Adapters.PrintApi

  require OpenTelemetry.Tracer, as: Tracer

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Domain.Contract
  alias OpenTelemetry.Span

  @prefix "/api/print-portal"
  @max_json_bytes 2 * 1024 * 1024
  @max_download_bytes 64 * 1024 * 1024

  @derive {Inspect, except: [:token]}
  @enforce_keys [:finch, :origin, :token]
  defstruct [:finch, :origin, :token, timeout_ms: 15_000, download_timeout_ms: 120_000]

  @type t :: %__MODULE__{
          finch: atom(),
          origin: String.t(),
          token: String.t(),
          timeout_ms: pos_integer(),
          download_timeout_ms: pos_integer()
        }

  @doc """
  Builds the adapter. `finch` names a started Finch pool;
  `origin` is `scheme://host[:port]` without a path.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @impl true
  def list_orders(api, query) do
    path = "/v1/orders" <> query_string(query)
    json(api, "listOrders", :get, path, "/v1/orders", nil, :order_list_response)
  end

  @impl true
  def get_order(api, id),
    do: json(api, "getOrder", :get, "/v1/orders/#{seg(id)}", "/v1/orders/:id", nil, :order_response)

  @impl true
  def collect(api, id, %{revision: revision}, pre) do
    body = {"application/json", JSON.encode!(%{revision: revision})}

    json(
      api,
      "collectFiles",
      :post,
      "/v1/orders/#{seg(id)}/collected",
      "/v1/orders/:id/collected",
      {body, pre},
      :order_response
    )
  end

  @impl true
  def mark_printed(api, id, %{revision: revision, quote_id: quote_id}, pre) do
    body = {"application/json", JSON.encode!(%{revision: revision, quoteId: quote_id})}

    json(
      api,
      "markPrinted",
      :post,
      "/v1/orders/#{seg(id)}/printed",
      "/v1/orders/:id/printed",
      {body, pre},
      :order_response
    )
  end

  @impl true
  def submit_quote(api, id, input, pre) do
    fields = [
      {"amountCents", Integer.to_string(input.amount_cents)},
      {"orderRevision", Integer.to_string(input.order_revision)}
    ]

    json(
      api,
      "submitQuote",
      :post,
      "/v1/orders/#{seg(id)}/quotes",
      "/v1/orders/:id/quotes",
      {multipart(fields, input.file), pre},
      :order_response
    )
  end

  @impl true
  def get_close(api, competence) do
    json(
      api,
      "getMonthlyClose",
      :get,
      "/v1/monthly-closes/#{seg(competence)}",
      "/v1/monthly-closes/:competence",
      nil,
      :close_response
    )
  end

  @impl true
  def submit_invoice(api, competence, input, pre) do
    fields = [{"declaredTotalCents", Integer.to_string(input.declared_total_cents)}]

    json(
      api,
      "submitInvoice",
      :post,
      "/v1/monthly-closes/#{seg(competence)}/invoice",
      "/v1/monthly-closes/:competence/invoice",
      {multipart(fields, input.file), pre},
      :close_response
    )
  end

  # --- v2: batches ---

  @impl true
  def get_open_batch(api),
    do:
      json(
        api,
        "getOpenBatch",
        :get,
        "/v2/batches/open",
        "/v2/batches/open",
        nil,
        :open_batch_response
      )

  @impl true
  def list_batches(api, query) do
    path = "/v2/batches" <> query_string(query)
    json(api, "listBatches", :get, path, "/v2/batches", nil, :batch_list_response)
  end

  @impl true
  def get_batch(api, id),
    do:
      json(api, "getBatch", :get, "/v2/batches/#{seg(id)}", "/v2/batches/:id", nil, :batch_response)

  @impl true
  def collect_batch(api, id, pre) do
    json(
      api,
      "collectBatch",
      :post,
      "/v2/batches/#{seg(id)}/collected",
      "/v2/batches/:id/collected",
      {{"application/json", "{}"}, pre},
      :batch_response
    )
  end

  @impl true
  def submit_batch_quote(api, id, input, pre) do
    fields = [{"amountCents", Integer.to_string(input.amount_cents)}]

    json(
      api,
      "submitBatchQuote",
      :post,
      "/v2/batches/#{seg(id)}/quotes",
      "/v2/batches/:id/quotes",
      {multipart(fields, input.file), pre},
      :batch_response
    )
  end

  @impl true
  def mark_batch_printed(api, id, %{quote_id: quote_id}, pre) do
    json(
      api,
      "markBatchPrinted",
      :post,
      "/v2/batches/#{seg(id)}/printed",
      "/v2/batches/:id/printed",
      {{"application/json", JSON.encode!(%{quoteId: quote_id})}, pre},
      :batch_response
    )
  end

  @impl true
  def get_batch_close(api, competence) do
    json(
      api,
      "getBatchMonthlyClose",
      :get,
      "/v2/monthly-closes/#{seg(competence)}",
      "/v2/monthly-closes/:competence",
      nil,
      :batch_close_response
    )
  end

  @impl true
  def submit_batch_invoice(api, competence, input, pre) do
    fields = [{"declaredTotalCents", Integer.to_string(input.declared_total_cents)}]

    json(
      api,
      "submitBatchInvoice",
      :post,
      "/v2/monthly-closes/#{seg(competence)}/invoice",
      "/v2/monthly-closes/:competence/invoice",
      {multipart(fields, input.file), pre},
      :batch_close_response
    )
  end

  @impl true
  def download(api, target, acc, sink) do
    {path, template} = download_path(target)

    traced("downloadDocument", :get, template, fn span ->
      request = Finch.build(:get, api.origin <> @prefix <> path, base_headers(api))
      initial = %{status: nil, headers: %{}, acc: acc, size: 0, error: nil, buffer: []}

      result =
        Finch.stream_while(request, api.finch, initial, &download_step(&1, &2, sink),
          receive_timeout: api.download_timeout_ms,
          request_timeout: api.download_timeout_ms
        )

      finish_download(result, span)
    end)
  end

  # --- downloads ---

  defp download_path({:order_file, order_id, file_id}),
    do: {"/v1/orders/#{seg(order_id)}/files/#{seg(file_id)}", "/v1/orders/:id/files/:fileId"}

  defp download_path({:quote_file, order_id, quote_id}),
    do:
      {"/v1/orders/#{seg(order_id)}/quotes/#{seg(quote_id)}/file",
       "/v1/orders/:id/quotes/:quoteId/file"}

  defp download_path({:invoice_file, competence}),
    do: {"/v1/monthly-closes/#{seg(competence)}/invoice", "/v1/monthly-closes/:competence/invoice"}

  defp download_path({:batch_file, batch_id, order_id, file_id}),
    do:
      {"/v2/batches/#{seg(batch_id)}/orders/#{seg(order_id)}/files/#{seg(file_id)}",
       "/v2/batches/:id/orders/:orderId/files/:fileId"}

  defp download_path({:batch_quote_file, batch_id, quote_id}),
    do:
      {"/v2/batches/#{seg(batch_id)}/quotes/#{seg(quote_id)}/file",
       "/v2/batches/:id/quotes/:quoteId/file"}

  defp download_path({:batch_invoice_file, competence}),
    do: {"/v2/monthly-closes/#{seg(competence)}/invoice", "/v2/monthly-closes/:competence/invoice"}

  defp download_step({:status, status}, st, _sink), do: {:cont, %{st | status: status}}

  defp download_step({:headers, headers}, %{status: 200} = st, sink) do
    relayed = relayed_download_headers(headers)

    case Integer.parse(Map.get(relayed, "content-length", "")) do
      {length, ""} when length >= 0 and length <= @max_download_bytes ->
        {:cont, %{st | headers: relayed, acc: sink.({:head, relayed}, st.acc)}}

      _ ->
        {:halt, %{st | error: :bad_headers}}
    end
  end

  defp download_step({:headers, headers}, st, _sink),
    do: {:cont, %{st | headers: response_headers(headers)}}

  defp download_step({:data, data}, %{status: 200} = st, sink) do
    size = st.size + byte_size(data)

    if size > @max_download_bytes,
      do: {:halt, %{st | error: :too_large}},
      else: {:cont, %{st | size: size, acc: sink.({:data, data}, st.acc)}}
  end

  defp download_step({:data, data}, st, _sink) do
    size = st.size + byte_size(data)

    if size > @max_json_bytes,
      do: {:halt, %{st | error: :too_large}},
      else: {:cont, %{st | size: size, buffer: [st.buffer | data]}}
  end

  defp download_step(_other, st, _sink), do: {:cont, st}

  defp finish_download({:ok, %{status: 200, error: nil, headers: headers} = st}, span)
       when map_size(headers) > 0 do
    Span.set_attribute(span, :"http.response.status_code", 200)

    if Integer.to_string(st.size) == headers["content-length"],
      do: {:streamed, st.acc},
      else: interrupted(span, st, :short_body)
  end

  defp finish_download({:ok, %{status: 200} = st}, span) when st.headers == %{},
    do: unavailable(span, :bad_headers)

  defp finish_download({:ok, %{status: 200} = st}, span), do: interrupted(span, st, st.error)

  defp finish_download({:ok, %{error: nil} = st}, span) do
    Span.set_attribute(span, :"http.response.status_code", st.status)
    decode_error_response(st.status, st.headers, IO.iodata_to_binary(st.buffer), span)
  end

  defp finish_download({:ok, %{error: error}}, span), do: unavailable(span, error)

  defp finish_download({:error, _reason, %{status: 200, headers: h} = st}, span)
       when map_size(h) > 0,
       do: interrupted(span, st, :transport)

  defp finish_download({:error, reason, _st}, span), do: unavailable(span, transport(reason))

  defp interrupted(span, st, reason) do
    fail(span, reason)
    {:error, :interrupted, st.acc}
  end

  defp relayed_download_headers(headers) do
    for {k, v} <- headers,
        k = String.downcase(k),
        k in ["content-type", "content-length", "content-disposition"],
        into: %{},
        do: {k, v}
  end

  # --- JSON calls ---

  defp json(api, operation, method, path, template, payload, kind) do
    traced(operation, method, template, fn span ->
      {headers, body} =
        case payload do
          nil ->
            {base_headers(api), nil}

          {{content_type, body}, pre} ->
            {base_headers(api) ++ [{"content-type", content_type}] ++ precondition_headers(pre),
             body}
        end

      request = Finch.build(method, api.origin <> @prefix <> path, headers, body)
      initial = %{status: nil, headers: %{}, buffer: [], size: 0, error: nil}

      case Finch.stream_while(request, api.finch, initial, &json_step/2,
             receive_timeout: api.timeout_ms,
             request_timeout: api.timeout_ms
           ) do
        {:ok, %{error: nil} = st} ->
          Span.set_attribute(span, :"http.response.status_code", st.status)
          decode(kind, st.status, st.headers, IO.iodata_to_binary(st.buffer), span)

        {:ok, %{error: error}} ->
          unavailable(span, error)

        {:error, reason, _st} ->
          unavailable(span, transport(reason))
      end
    end)
  end

  defp json_step({:status, status}, st), do: {:cont, %{st | status: status}}
  defp json_step({:headers, headers}, st), do: {:cont, %{st | headers: response_headers(headers)}}

  defp json_step({:data, data}, st) do
    size = st.size + byte_size(data)

    if size > @max_json_bytes,
      do: {:halt, %{st | error: :too_large}},
      else: {:cont, %{st | size: size, buffer: [st.buffer | data]}}
  end

  defp json_step(_other, st), do: {:cont, st}

  defp decode(kind, status, headers, raw, span) when status in 200..299 do
    with {:ok, body} <- decode_json(raw),
         :ok <- Contract.validate(kind, body) do
      {:ok, response(status, body, headers)}
    else
      _ -> unavailable(span, :contract)
    end
  end

  defp decode(_kind, status, headers, raw, span),
    do: decode_error_response(status, headers, raw, span)

  # Contract errors relay; anything else (3xx, unknown 5xx bodies) is unavailable.
  defp decode_error_response(status, headers, raw, span) when status in 400..599 do
    with {:ok, body} <- decode_json(raw),
         :ok <- Contract.validate(:error_response, body) do
      {:ok, response(status, body, headers)}
    else
      _ -> unavailable(span, :contract)
    end
  end

  defp decode_error_response(_status, _headers, _raw, span), do: unavailable(span, :status)

  defp decode_json(raw) do
    case JSON.decode(raw) do
      {:ok, %{} = body} -> {:ok, body}
      _ -> :error
    end
  end

  defp response(status, body, headers) do
    %Response{
      status: status,
      body: body,
      etag: headers["etag"],
      replayed: headers["idempotency-replayed"] == "true",
      retry_after: headers["retry-after"]
    }
  end

  defp response_headers(headers) do
    for {k, v} <- headers,
        k = String.downcase(k),
        k in ["etag", "idempotency-replayed", "retry-after", "content-type"],
        into: %{},
        do: {k, v}
  end

  # --- request building ---

  defp base_headers(api) do
    [
      {"authorization", "Bearer " <> api.token},
      {"accept", "application/json"},
      {"user-agent", "incluir-print-portal-elixir"}
    ] ++ request_id_header()
  end

  # Correlation id of the portal request (set by the HTTP layer), if any.
  defp request_id_header do
    case Logger.metadata()[:request_id] do
      id when is_binary(id) -> [{"x-request-id", id}]
      _ -> []
    end
  end

  defp precondition_headers(pre) do
    [{"if-match", pre[:if_match]}, {"idempotency-key", pre[:idempotency_key]}]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp query_string(query) do
    params =
      query
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> {Atom.to_string(k), to_string(v)} end)

    if params == [], do: "", else: "?" <> URI.encode_query(params)
  end

  # Path segments are validated upstream of this module; encode anyway.
  defp seg(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp multipart(fields, file) do
    boundary = "----frame" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    parts =
      Enum.map(fields, fn {name, value} ->
        [
          "--",
          boundary,
          "\r\ncontent-disposition: form-data; name=\"",
          name,
          "\"\r\n\r\n",
          value,
          "\r\n"
        ]
      end)

    file_part = [
      "--",
      boundary,
      "\r\ncontent-disposition: form-data; name=\"file\"; filename=\"",
      quoted_filename(file.name),
      "\"\r\ncontent-type: ",
      file.content_type,
      "\r\n\r\n",
      file.bytes,
      "\r\n--",
      boundary,
      "--\r\n"
    ]

    {"multipart/form-data; boundary=" <> boundary, IO.iodata_to_binary([parts, file_part])}
  end

  # Quotes, backslashes and line breaks cannot appear inside the quoted
  # filename; the upstream sanitizes the name again.
  defp quoted_filename(name), do: String.replace(name, ~r/["\\\r\n]/, "_")

  # --- tracing ---

  defp traced(operation, method, template, fun) do
    attributes = %{
      "http.request.method": method |> Atom.to_string() |> String.upcase(),
      "url.template": @prefix <> template,
      "peer.service": "incluir-print-api"
    }

    Tracer.with_span "http.print_api." <> operation, %{kind: :client, attributes: attributes} do
      span = Tracer.current_span_ctx()

      try do
        result = fun.(span)
        if not failed?(result), do: Span.set_status(span, OpenTelemetry.status(:ok))
        result
      rescue
        # Type only — never the message or stack (they may carry data).
        error ->
          Span.set_attribute(span, :"error.type", inspect(error.__struct__))
          Span.set_status(span, OpenTelemetry.status(:error, "exception"))
          reraise error, __STACKTRACE__
      end
    end
  end

  defp failed?({:error, _}), do: true
  defp failed?({:error, _, _}), do: true
  defp failed?(_result), do: false

  defp transport(%Mint.TransportError{reason: :timeout}), do: :timeout
  defp transport(_reason), do: :transport

  defp unavailable(span, reason) do
    fail(span, reason)
    {:error, :unavailable}
  end

  defp fail(span, reason) do
    Span.set_attribute(span, :"error.type", Atom.to_string(reason))
    Span.set_status(span, OpenTelemetry.status(:error, "upstream #{reason}"))
  end
end
