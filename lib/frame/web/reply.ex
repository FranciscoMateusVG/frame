defmodule Frame.Web.Reply do
  @moduledoc """
  Response helpers shared by the JSON API and the HTML pages: JSON bodies,
  the error envelope `{error:{code,message,requestId}}` (never echoing
  input), relaying an upstream answer, and streaming a download.
  """

  import Plug.Conn

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Errors.PortalError
  alias Frame.UseCases.DownloadDocument

  @doc "Sends a JSON body."
  @spec json(Plug.Conn.t(), pos_integer(), map()) :: Plug.Conn.t()
  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  @doc "Sends a portal error in the contract envelope."
  @spec error(Plug.Conn.t(), PortalError.t()) :: Plug.Conn.t()
  def error(conn, %PortalError{} = e) do
    conn
    |> retry_after(e.retry_after && Integer.to_string(e.retry_after))
    |> json(e.status, envelope(conn, e.code, e.message))
  end

  @doc "Sends a portal error by reason."
  @spec error(Plug.Conn.t(), PortalError.reason(), pos_integer() | nil) :: Plug.Conn.t()
  def error(conn, reason, retry_after \\ nil),
    do: error(conn, PortalError.exception({reason, retry_after}))

  @doc """
  Relays an upstream answer: same status and body, plus ETag,
  `Idempotency-Replayed` and `Retry-After`. Error envelopes are rebuilt with
  the portal's request id.
  """
  @spec relay(Plug.Conn.t(), Response.t()) :: Plug.Conn.t()
  def relay(conn, %Response{} = r) do
    body =
      case r.body do
        %{"error" => %{"code" => code, "message" => message}} -> envelope(conn, code, message)
        body -> body
      end

    conn
    |> maybe_header("etag", r.etag)
    |> maybe_header("idempotency-replayed", if(r.replayed, do: "true"))
    |> retry_after(r.retry_after)
    |> json(r.status, body)
  end

  @doc "The error envelope with this request's id."
  @spec envelope(Plug.Conn.t(), String.t(), String.t()) :: map()
  def envelope(conn, code, message),
    do: %{error: %{code: code, message: message, requestId: conn.assigns[:request_id] || ""}}

  @doc """
  Streams a document from the upstream to the client. Non-200 upstream
  answers are relayed as JSON errors (`on_error` may render something else).
  """
  @spec download(Plug.Conn.t(), map(), Frame.Adapters.PrintApi.target(), (Plug.Conn.t(),
                                                                          Response.t()
                                                                          | PortalError.t() ->
                                                                            Plug.Conn.t())) ::
          Plug.Conn.t()
  def download(conn, deps, target, on_error \\ &download_error/2) do
    case DownloadDocument.download_document(deps, target, conn, &sink/2) do
      {:streamed, conn} -> conn
      {:ok, %Response{} = response} -> on_error.(conn, response)
      {:error, %PortalError{} = error} -> on_error.(conn, error)
      {:error, :interrupted, %Plug.Conn{state: :chunked} = conn} -> halt(conn)
      {:error, :interrupted, conn} -> on_error.(conn, PortalError.exception(:upstream_unavailable))
    end
  end

  defp download_error(conn, %Response{} = r), do: relay(conn, r)
  defp download_error(conn, %PortalError{} = e), do: error(conn, e)

  defp sink({:head, headers}, conn) do
    conn
    |> put_resp_header("content-type", safe_type(headers["content-type"]))
    |> put_resp_header("content-length", headers["content-length"])
    |> put_resp_header("content-disposition", safe_disposition(headers["content-disposition"]))
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
    |> send_chunked(200)
  end

  # A client that went away stops receiving; the (bounded) upstream read ends.
  defp sink({:data, data}, conn) do
    case chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  defp safe_type(type) when is_binary(type) do
    if Regex.match?(~r{^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$}, type),
      do: type,
      else: "application/octet-stream"
  end

  defp safe_type(_type), do: "application/octet-stream"

  defp safe_disposition("attachment;" <> _ = value) do
    if Regex.match?(~r/^[\x20-\x7E]+$/, value),
      do: value,
      else: ~s(attachment; filename="arquivo")
  end

  defp safe_disposition(_value), do: ~s(attachment; filename="arquivo")

  defp maybe_header(conn, _name, nil), do: conn
  defp maybe_header(conn, name, value), do: put_resp_header(conn, name, value)

  defp retry_after(conn, nil), do: conn

  defp retry_after(conn, value) do
    if Regex.match?(~r/^\d{1,6}$/, value),
      do: put_resp_header(conn, "retry-after", value),
      else: conn
  end
end
