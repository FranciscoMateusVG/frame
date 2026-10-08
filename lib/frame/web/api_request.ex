defmodule Frame.Web.ApiRequest do
  @moduledoc """
  Request plumbing shared by the JSON controllers: the strict JSON body
  reader (capped, object only), single-valued headers, the browser-command
  checks (exact Origin, CSRF header) and the relayed preconditions.
  """

  import Plug.Conn

  alias Frame.Domain.Session
  alias Frame.Web.Security

  @json_limit 16_384

  @doc "Reads a JSON object body (`Content-Type: application/json`, ≤ 16 KiB)."
  @spec json_body(Plug.Conn.t()) :: {:ok, Plug.Conn.t(), map()} | {:error, Plug.Conn.t(), atom()}
  def json_body(conn) do
    with ["application/json" <> _] <- get_req_header(conn, "content-type"),
         {:ok, raw, conn} <- read_body(conn, length: @json_limit),
         {:ok, %{} = body} <- JSON.decode(raw) do
      {:ok, conn, body}
    else
      {:more, _partial, conn} -> {:error, conn, :invalid_request}
      _ -> {:error, conn, :invalid_request}
    end
  end

  @doc "A header present exactly once, else `nil`."
  @spec header(Plug.Conn.t(), String.t()) :: String.t() | nil
  def header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _ -> nil
    end
  end

  @doc "`:ok` when the request's Origin is exactly the portal origin."
  @spec origin(Plug.Conn.t(), map()) :: :ok | {:error, :csrf_failed}
  def origin(conn, deps) do
    if Security.same_origin?(conn, deps.portal_origin), do: :ok, else: {:error, :csrf_failed}
  end

  @doc "`:ok` when `X-CSRF-Token` matches the session's token."
  @spec csrf(Plug.Conn.t(), Session.t()) :: :ok | {:error, :csrf_failed}
  def csrf(conn, session) do
    if Security.csrf_valid?(header(conn, "x-csrf-token"), session),
      do: :ok,
      else: {:error, :csrf_failed}
  end

  @doc "`If-Match` and `Idempotency-Key`, relayed as given; unusable values are refused."
  @spec preconditions(Plug.Conn.t()) ::
          {:ok, %{if_match: String.t() | nil, idempotency_key: String.t() | nil}}
          | {:error, :invalid_request}
  def preconditions(conn) do
    if_match = header(conn, "if-match")
    key = header(conn, "idempotency-key")

    if Enum.all?([if_match, key], &(is_nil(&1) or Regex.match?(~r/^[\x21-\x7E]{1,200}$/, &1))),
      do: {:ok, %{if_match: if_match, idempotency_key: key}},
      else: {:error, :invalid_request}
  end

  @doc "Boundary parser result → `{:ok, value}` or `{:error, :invalid_request}`."
  @spec parse({:ok, term()} | :error) :: {:ok, term()} | {:error, :invalid_request}
  def parse({:ok, value}), do: {:ok, value}
  def parse(:error), do: {:error, :invalid_request}
end
