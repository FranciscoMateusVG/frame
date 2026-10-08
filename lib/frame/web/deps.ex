defmodule Frame.Web.Deps do
  @moduledoc """
  The dependency map of the portal (print API, session store, login
  limiter, clock, observability, password, origins), as built by the
  composition root and handed to the endpoint at start (`:frame_deps`).

  It travels with the request: `Frame.Web.Edge` puts it into the conn
  (`conn.private.frame_deps`) unless the caller already did — tests pass
  their own per conn, the way the composition root passes its own to the
  endpoint. A LiveView resolves it once at mount (from the conn of the
  request when there is one, else from its endpoint) and keeps it in
  `socket.private`, never in assigns.
  """

  @key :frame_deps

  @doc "The deps of this conn or LiveView socket."
  @spec fetch(Plug.Conn.t() | Phoenix.LiveView.Socket.t()) :: map()
  def fetch(%Plug.Conn{private: %{@key => deps}}), do: deps
  def fetch(%Plug.Conn{private: %{phoenix_endpoint: endpoint}}), do: endpoint.config(@key)
  def fetch(%Phoenix.LiveView.Socket{private: %{@key => deps}}), do: deps

  def fetch(%Phoenix.LiveView.Socket{private: %{connect_info: %Plug.Conn{} = conn}}),
    do: fetch(conn)

  def fetch(%Phoenix.LiveView.Socket{endpoint: endpoint}), do: endpoint.config(@key)

  @doc "Puts the deps into the conn (no-op when already present)."
  @spec put(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put(%Plug.Conn{private: %{@key => _}} = conn, _deps), do: conn
  def put(conn, deps), do: Plug.Conn.put_private(conn, @key, deps)

  @doc "Resolves the deps of a mounting LiveView and keeps them in `socket.private`."
  @spec put_live(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def put_live(socket), do: Phoenix.LiveView.put_private(socket, @key, fetch(socket))
end
