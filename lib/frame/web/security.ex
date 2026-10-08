defmodule Frame.Web.Security do
  @moduledoc """
  Browser-facing security primitives of the portal (spec §5):

    * session cookies — `__Host-print_session` (authenticated) and
      `__Host-print_presession` (login CSRF binding): Secure, HttpOnly,
      SameSite=Lax, Path=/, no Domain;
    * exact `Origin` check for every state-changing request (absent Origin
      is refused);
    * CSRF token comparison in constant time;
    * client address resolution with an explicit trusted-proxy list
      (`X-Forwarded-For` from anyone else is ignored);
    * response hardening headers.
  """

  import Plug.Conn

  alias Frame.Adapters.SessionStore
  alias Frame.Domain.Session

  @session_cookie "__Host-print_session"
  @pre_session_cookie "__Host-print_presession"

  @doc "Name of the authenticated session cookie."
  @spec session_cookie() :: String.t()
  def session_cookie, do: @session_cookie

  @doc "Name of the pre-session (login CSRF) cookie."
  @spec pre_session_cookie() :: String.t()
  def pre_session_cookie, do: @pre_session_cookie

  @doc "Hardening headers for every response."
  @spec put_security_headers(Plug.Conn.t(), boolean()) :: Plug.Conn.t()
  def put_security_headers(conn, https?) do
    conn
    |> merge_resp_headers([
      {"x-content-type-options", "nosniff"},
      {"x-frame-options", "DENY"},
      {"referrer-policy", "same-origin"},
      {"cross-origin-opener-policy", "same-origin"},
      {"cross-origin-resource-policy", "same-origin"},
      {"permissions-policy", "camera=(), microphone=(), geolocation=()"},
      {"content-security-policy",
       "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; " <>
         "connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"},
      {"cache-control", "no-store"}
    ])
    |> then(fn conn ->
      if https?,
        do: put_resp_header(conn, "strict-transport-security", "max-age=31536000"),
        else: conn
    end)
  end

  @doc "Reads a cookie value (request cookies only)."
  @spec cookie(Plug.Conn.t(), String.t()) :: String.t() | nil
  def cookie(conn, name) do
    conn = fetch_cookies(conn)

    case conn.req_cookies[name] do
      value when is_binary(value) and byte_size(value) in 1..128 -> value
      _ -> nil
    end
  end

  @doc "Sets a host-only session cookie."
  @spec put_cookie(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def put_cookie(conn, name, value) do
    put_resp_cookie(conn, name, value,
      http_only: true,
      secure: true,
      same_site: "Lax",
      path: "/"
    )
  end

  @doc "Expires a host-only session cookie."
  @spec drop_cookie(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def drop_cookie(conn, name) do
    delete_resp_cookie(conn, name, http_only: true, secure: true, same_site: "Lax", path: "/")
  end

  @doc "The live authenticated session of this request, if any."
  @spec current_session(Plug.Conn.t(), SessionStore.t()) :: {:ok, Session.t()} | :error
  def current_session(conn, store) do
    case cookie(conn, @session_cookie) do
      nil -> :error
      id -> SessionStore.fetch(store, id, :authenticated)
    end
  end

  @doc "True when the request's `Origin` header is exactly the portal origin."
  @spec same_origin?(Plug.Conn.t(), String.t()) :: boolean()
  def same_origin?(conn, portal_origin) do
    case get_req_header(conn, "origin") do
      [origin] -> origin == portal_origin
      _ -> false
    end
  end

  @doc "The LiveView socket id (PubSub topic) of a session id: `portal_session:<sha256>`."
  @spec live_socket_id(String.t()) :: String.t()
  def live_socket_id(session_id),
    do: "portal_session:" <> Base.encode16(:crypto.hash(:sha256, session_id), case: :lower)

  @doc """
  Disconnects every live page of a session (logout, login rotation): its
  LiveView sockets drop at once instead of living on until their next event.
  """
  @spec disconnect_live(Plug.Conn.t(), String.t()) :: :ok
  def disconnect_live(%Plug.Conn{private: %{phoenix_endpoint: endpoint}}, session_id) do
    _ = endpoint.broadcast(live_socket_id(session_id), "disconnect", %{})
    :ok
  end

  def disconnect_live(_conn, _session_id), do: :ok

  @doc "Constant-time comparison of a presented CSRF token with the session's."
  @spec csrf_valid?(String.t() | nil, Session.t()) :: boolean()
  def csrf_valid?(presented, %Session{csrf_token: expected}) when is_binary(presented),
    do: Plug.Crypto.secure_compare(presented, expected)

  def csrf_valid?(_presented, _session), do: false

  @doc """
  The client address as a string. `X-Forwarded-For` is honoured only when
  the direct peer is a trusted proxy; then the right-most address that is
  not itself a trusted proxy is the client.
  """
  @spec client_ip(Plug.Conn.t(), [Frame.Config.cidr()]) :: String.t()
  def client_ip(conn, trusted) do
    peer = conn.remote_ip

    if trusted != [] and trusted?(peer, trusted) do
      conn
      |> get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.map(&:inet.parse_strict_address(String.to_charlist(&1)))
      |> Enum.reduce_while(peer, &forwarded_hop(&1, &2, trusted))
      |> format_ip()
    else
      format_ip(peer)
    end
  end

  # Walks X-Forwarded-For right to left while the hops are trusted proxies.
  defp forwarded_hop({:ok, ip}, _acc, trusted),
    do: if(trusted?(ip, trusted), do: {:cont, ip}, else: {:halt, ip})

  defp forwarded_hop({:error, _}, acc, _trusted), do: {:halt, acc}

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()

  @doc "True when `ip` belongs to one of the CIDRs."
  @spec trusted?(:inet.ip_address(), [Frame.Config.cidr()]) :: boolean()
  def trusted?(ip, cidrs), do: Enum.any?(cidrs, &in_cidr?(ip, &1))

  defp in_cidr?(ip, {net, prefix}) when tuple_size(ip) == tuple_size(net) do
    width = if tuple_size(ip) == 4, do: 32, else: 128
    shift = width - prefix
    Bitwise.bsr(to_integer(ip), shift) == Bitwise.bsr(to_integer(net), shift)
  end

  defp in_cidr?(_ip, _cidr), do: false

  defp to_integer({_, _, _, _} = ip), do: fold(ip, 8)
  defp to_integer(ip), do: fold(ip, 16)

  defp fold(ip, bits),
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &(Bitwise.bsl(&2, bits) + &1))
end
