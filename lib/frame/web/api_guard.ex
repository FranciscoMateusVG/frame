defmodule Frame.Web.ApiGuard do
  @moduledoc """
  The `:api` pipeline guard. The browser authenticates only with the
  session cookie: a request that carries credentials in `Authorization`
  (e.g. a leaked service token) is refused outright with 400 — never
  ignored, never relayed (spec §4.5).
  """

  @behaviour Plug

  alias Frame.Web.Reply

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Plug.Conn.get_req_header(conn, "authorization") == [],
      do: conn,
      else: conn |> Reply.error(:invalid_request) |> Plug.Conn.halt()
  end
end
