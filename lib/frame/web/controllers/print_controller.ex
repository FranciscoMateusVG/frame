defmodule Frame.Web.PrintController do
  @moduledoc """
  `/api/print/v1/...` (spec §4.5): the ten service routes of §4.3 with the
  session cookie instead of the bearer token; and `/api/print/v2/...`: the
  batch downloads (member files, current quote, monthly NF) the batch
  pages link to.

  Every route needs a live session (401 `UNAUTHENTICATED`); commands also
  need the exact Origin and `X-CSRF-Token` (403 `CSRF_FAILED`). `If-Match`
  and `Idempotency-Key` are relayed for the upstream to enforce. Cookies
  are never forwarded and the upstream path is rebuilt from validated ids
  only — this is not a proxy for arbitrary paths or hosts.
  """

  use Frame.Web, :controller

  alias Frame.Domain.Competence
  alias Frame.Domain.Document
  alias Frame.Domain.Requests
  alias Frame.UseCases
  alias Frame.Web.ApiRequest
  alias Frame.Web.Deps
  alias Frame.Web.Multipart
  alias Frame.Web.Reply
  alias Frame.Web.Security

  plug :authorize

  # Session first; commands also need the exact Origin and the CSRF header.
  defp authorize(conn, _opts) do
    deps = Deps.fetch(conn)

    with {:ok, session} <- Security.current_session(conn, deps.session_store),
         :ok <- command_allowed(conn, deps, session) do
      conn
    else
      :error -> conn |> Reply.error(:unauthenticated) |> halt()
      {:error, reason} -> conn |> Reply.error(reason) |> halt()
    end
  end

  defp command_allowed(%Plug.Conn{method: "GET"}, _deps, _session), do: :ok

  defp command_allowed(conn, deps, session) do
    with :ok <- ApiRequest.origin(conn, deps), do: ApiRequest.csrf(conn, session)
  end

  @doc false
  def list_orders(conn, _params) do
    conn = fetch_query_params(conn)

    case Requests.list_query(conn.query_params) do
      {:ok, query} -> respond(conn, UseCases.ListOrders.list_orders(Deps.fetch(conn), query))
      :error -> Reply.error(conn, :invalid_request)
    end
  end

  @doc false
  def get_order(conn, %{"id" => id}) do
    with_ids(conn, [id], fn [id] ->
      respond(conn, UseCases.GetOrder.get_order(Deps.fetch(conn), id))
    end)
  end

  @doc false
  def order_file(conn, %{"id" => id, "file_id" => file_id}) do
    with_ids(conn, [id, file_id], fn [id, file_id] ->
      Reply.download(conn, Deps.fetch(conn), {:order_file, id, file_id})
    end)
  end

  @doc false
  def quote_file(conn, %{"id" => id, "quote_id" => quote_id}) do
    with_ids(conn, [id, quote_id], fn [id, quote_id] ->
      Reply.download(conn, Deps.fetch(conn), {:quote_file, id, quote_id})
    end)
  end

  @doc false
  def collected(conn, %{"id" => id}) do
    with_command(conn, [id], &Requests.collected/1, fn conn, [id], input, pre ->
      respond(conn, UseCases.CollectFiles.collect_files(Deps.fetch(conn), id, input, pre))
    end)
  end

  @doc false
  def printed(conn, %{"id" => id}) do
    with_command(conn, [id], &Requests.printed/1, fn conn, [id], input, pre ->
      respond(conn, UseCases.MarkPrinted.mark_printed(Deps.fetch(conn), id, input, pre))
    end)
  end

  @doc false
  def submit_quote(conn, %{"id" => id}) do
    with_upload(conn, [id], &Requests.quote_fields/1, fn conn, [id], fields, file, pre ->
      input = Map.put(fields, :file, file)
      respond(conn, UseCases.SubmitQuote.submit_quote(Deps.fetch(conn), id, input, pre))
    end)
  end

  @doc false
  def monthly_close(conn, %{"competence" => competence}) do
    with_competence(conn, competence, fn c ->
      respond(conn, UseCases.GetMonthlyClose.get_monthly_close(Deps.fetch(conn), c))
    end)
  end

  @doc false
  def invoice_file(conn, %{"competence" => competence}) do
    with_competence(conn, competence, fn c ->
      Reply.download(conn, Deps.fetch(conn), {:invoice_file, c})
    end)
  end

  @doc false
  def submit_invoice(conn, %{"competence" => competence}) do
    with_competence(conn, competence, fn c ->
      with_upload(conn, [], &Requests.invoice_fields/1, fn conn, [], fields, file, pre ->
        input = Map.put(fields, :file, file)
        respond(conn, UseCases.SubmitInvoice.submit_invoice(Deps.fetch(conn), c, input, pre))
      end)
    end)
  end

  @doc false
  def batch_file(conn, %{"id" => id, "order_id" => order_id, "file_id" => file_id}) do
    with_ids(conn, [id, order_id, file_id], fn [id, order_id, file_id] ->
      Reply.download(conn, Deps.fetch(conn), {:batch_file, id, order_id, file_id})
    end)
  end

  @doc false
  def batch_quote_file(conn, %{"id" => id, "quote_id" => quote_id}) do
    with_ids(conn, [id, quote_id], fn [id, quote_id] ->
      Reply.download(conn, Deps.fetch(conn), {:batch_quote_file, id, quote_id})
    end)
  end

  @doc false
  def batch_invoice_file(conn, %{"competence" => competence}) do
    with_competence(conn, competence, fn c ->
      Reply.download(conn, Deps.fetch(conn), {:batch_invoice_file, c})
    end)
  end

  # --- request plumbing ---

  # Non-UUID ids cannot exist upstream: 404 without a round trip.
  defp with_ids(conn, ids, fun) do
    if Enum.all?(ids, &match?({:ok, _}, Requests.uuid(&1))),
      do: fun.(ids),
      else: Reply.error(conn, :not_found)
  end

  defp with_competence(conn, competence, fun) do
    case Competence.parse(competence) do
      {:ok, c} -> fun.(Competence.to_string(c))
      :error -> Reply.error(conn, :invalid_competence)
    end
  end

  # Body first (as the upstream does), then preconditions.
  defp with_command(conn, ids, parser, fun) do
    with_ids(conn, ids, fn ids ->
      with {:ok, conn, body} <- ApiRequest.json_body(conn),
           {:ok, input} <- ApiRequest.parse(parser.(body)),
           {:ok, pre} <- ApiRequest.preconditions(conn) do
        fun.(conn, ids, input, pre)
      else
        {:error, conn, reason} -> Reply.error(conn, reason)
        {:error, reason} -> Reply.error(conn, reason)
      end
    end)
  end

  defp with_upload(conn, ids, parser, fun) do
    with_ids(conn, ids, fn ids ->
      with {:ok, conn, fields, file} <- Multipart.read(conn, Document.max_body_bytes()),
           {:ok, input} <- ApiRequest.parse(parser.(fields)),
           {:ok, pre} <- ApiRequest.preconditions(conn) do
        fun.(conn, ids, input, file, pre)
      else
        {:error, conn, :too_large} -> Reply.error(conn, :file_too_large)
        {:error, conn, :invalid} -> Reply.error(conn, :invalid_request)
        {:error, reason} -> Reply.error(conn, reason)
      end
    end)
  end

  defp respond(conn, {:ok, response}), do: Reply.relay(conn, response)
  defp respond(conn, {:error, error}), do: Reply.error(conn, error)
end
