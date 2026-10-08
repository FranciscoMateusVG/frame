defmodule Frame.Web.OriginGuard do
  @moduledoc """
  Refuses a LiveView websocket upgrade that carries no `Origin` (spec §5:
  browser commands without Origin are rejected). Phoenix's `check_origin`
  refuses a *different* Origin but lets an absent one through, and socket
  dispatch runs before any endpoint plug — so this wraps the endpoint's
  `call/2` (compiled after `use Phoenix.Endpoint`).
  """

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(%Plug.Conn{path_info: ["live" | _]} = conn, opts) do
        if Plug.Conn.get_req_header(conn, "origin") == [] do
          conn |> Plug.Conn.send_resp(403, "") |> Plug.Conn.halt()
        else
          super(conn, opts)
        end
      end

      def call(conn, opts), do: super(conn, opts)
    end
  end
end
