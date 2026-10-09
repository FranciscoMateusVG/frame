defmodule Frame.Adapters.PrintApi do
  @moduledoc """
  PrintApi — the port (behaviour) for the Incluir print-portal service API
  (`/api/print-portal/v1`, spec §4.3, and the batch contract
  `/api/print-portal/v2`; frozen contracts in monorepo-incluir).

  Implementations:

    * `Frame.Adapters.PrintApi.Http` — the real one: Finch, bearer service
      token, fixed origin, no redirects, timeouts and byte caps.
    * `Frame.Adapters.PrintApi.Memory` — an in-memory fake of the Hono state
      machine (ETags, idempotency, transitions) for tests, examples and
      local runs.

  Every call answers with the upstream's HTTP status and decoded body, so
  contract errors (404/409/412/428/…) reach the caller unchanged.
  `{:error, :unavailable}` means no trustworthy answer: transport failure,
  timeout, oversized or off-contract response.

  Path parameters are typed values the portal validated (UUIDs, `YYYY-MM`);
  no caller-supplied path, host or URL ever reaches the upstream request.
  """

  defmodule Response do
    @moduledoc "An upstream answer: status, decoded JSON body and the headers the portal relays."
    @enforce_keys [:status, :body]
    defstruct [:status, :body, etag: nil, replayed: false, retry_after: nil]

    @type t :: %__MODULE__{
            status: 100..599,
            body: map() | nil,
            etag: String.t() | nil,
            replayed: boolean(),
            retry_after: String.t() | nil
          }
  end

  @typedoc "Any struct whose module implements this behaviour."
  @type t :: struct()

  @type result :: {:ok, Response.t()} | {:error, :unavailable}

  @typedoc "Mutation preconditions, relayed verbatim (the upstream decides)."
  @type preconditions :: %{if_match: String.t() | nil, idempotency_key: String.t() | nil}

  @typedoc "A supplier document to upload."
  @type upload :: %{name: String.t(), content_type: String.t(), bytes: binary()}

  @type list_query :: %{
          optional(:status) => String.t(),
          optional(:limit) => pos_integer(),
          optional(:cursor) => String.t()
        }

  @typedoc "A downloadable object, addressed only by validated ids."
  @type target ::
          {:order_file, order_id :: String.t(), file_id :: String.t()}
          | {:quote_file, order_id :: String.t(), quote_id :: String.t()}
          | {:invoice_file, competence :: String.t()}
          | {:batch_file, batch_id :: String.t(), order_id :: String.t(), file_id :: String.t()}
          | {:batch_quote_file, batch_id :: String.t(), quote_id :: String.t()}
          | {:batch_invoice_file, competence :: String.t()}

  @typedoc """
  A download sink: receives `{:head, headers}` once (for a 200), then
  `{:data, chunk}` for each chunk, threading an accumulator. `headers` holds
  `"content-type"`, `"content-length"` and `"content-disposition"`.
  """
  @type sink(acc) :: ({:head, %{String.t() => String.t()}} | {:data, binary()}, acc -> acc)

  @type download_result(acc) ::
          {:streamed, acc}
          | {:ok, Response.t()}
          | {:error, :unavailable}
          | {:error, :interrupted, acc}

  @callback list_orders(t(), list_query()) :: result()
  @callback get_order(t(), String.t()) :: result()
  @callback collect(t(), String.t(), %{revision: pos_integer()}, preconditions()) :: result()
  @callback submit_quote(
              t(),
              String.t(),
              %{amount_cents: pos_integer(), order_revision: pos_integer(), file: upload()},
              preconditions()
            ) :: result()
  @callback mark_printed(
              t(),
              String.t(),
              %{revision: pos_integer(), quote_id: String.t()},
              preconditions()
            ) :: result()
  @callback get_close(t(), String.t()) :: result()
  @callback submit_invoice(
              t(),
              String.t(),
              %{declared_total_cents: pos_integer(), file: upload()},
              preconditions()
            ) :: result()
  @callback download(t(), target(), acc, sink(acc)) :: download_result(acc) when acc: term()

  # --- v2: batches ---

  @callback get_open_batch(t()) :: result()
  @callback list_batches(t(), list_query()) :: result()
  @callback get_batch(t(), String.t()) :: result()
  @callback collect_batch(t(), String.t(), preconditions()) :: result()
  @callback submit_batch_quote(
              t(),
              String.t(),
              %{amount_cents: pos_integer(), file: upload()},
              preconditions()
            ) :: result()
  @callback mark_batch_printed(t(), String.t(), %{quote_id: String.t()}, preconditions()) ::
              result()
  @callback get_batch_close(t(), String.t()) :: result()
  @callback submit_batch_invoice(
              t(),
              String.t(),
              %{declared_total_cents: pos_integer(), file: upload()},
              preconditions()
            ) :: result()

  @spec list_orders(t(), list_query()) :: result()
  def list_orders(%impl{} = api, query), do: impl.list_orders(api, query)

  @spec get_order(t(), String.t()) :: result()
  def get_order(%impl{} = api, id), do: impl.get_order(api, id)

  @spec collect(t(), String.t(), map(), preconditions()) :: result()
  def collect(%impl{} = api, id, input, pre), do: impl.collect(api, id, input, pre)

  @spec submit_quote(t(), String.t(), map(), preconditions()) :: result()
  def submit_quote(%impl{} = api, id, input, pre), do: impl.submit_quote(api, id, input, pre)

  @spec mark_printed(t(), String.t(), map(), preconditions()) :: result()
  def mark_printed(%impl{} = api, id, input, pre), do: impl.mark_printed(api, id, input, pre)

  @spec get_close(t(), String.t()) :: result()
  def get_close(%impl{} = api, competence), do: impl.get_close(api, competence)

  @spec submit_invoice(t(), String.t(), map(), preconditions()) :: result()
  def submit_invoice(%impl{} = api, competence, input, pre),
    do: impl.submit_invoice(api, competence, input, pre)

  @spec download(t(), target(), acc, sink(acc)) :: download_result(acc) when acc: term()
  def download(%impl{} = api, target, acc, sink), do: impl.download(api, target, acc, sink)

  @spec get_open_batch(t()) :: result()
  def get_open_batch(%impl{} = api), do: impl.get_open_batch(api)

  @spec list_batches(t(), list_query()) :: result()
  def list_batches(%impl{} = api, query), do: impl.list_batches(api, query)

  @spec get_batch(t(), String.t()) :: result()
  def get_batch(%impl{} = api, id), do: impl.get_batch(api, id)

  @spec collect_batch(t(), String.t(), preconditions()) :: result()
  def collect_batch(%impl{} = api, id, pre), do: impl.collect_batch(api, id, pre)

  @spec submit_batch_quote(t(), String.t(), map(), preconditions()) :: result()
  def submit_batch_quote(%impl{} = api, id, input, pre),
    do: impl.submit_batch_quote(api, id, input, pre)

  @spec mark_batch_printed(t(), String.t(), map(), preconditions()) :: result()
  def mark_batch_printed(%impl{} = api, id, input, pre),
    do: impl.mark_batch_printed(api, id, input, pre)

  @spec get_batch_close(t(), String.t()) :: result()
  def get_batch_close(%impl{} = api, competence), do: impl.get_batch_close(api, competence)

  @spec submit_batch_invoice(t(), String.t(), map(), preconditions()) :: result()
  def submit_batch_invoice(%impl{} = api, competence, input, pre),
    do: impl.submit_batch_invoice(api, competence, input, pre)
end
