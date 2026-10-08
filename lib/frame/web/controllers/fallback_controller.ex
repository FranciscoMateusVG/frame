defmodule Frame.Web.FallbackController do
  @moduledoc """
  Every unrouted path or method: 405 with `Allow` when the path exists for
  other methods, 404 otherwise — in the JSON envelope under `/api`, as an
  HTML page elsewhere.
  """

  use Frame.Web, :controller

  alias Frame.Web.PageHTML
  alias Frame.Web.Reply

  @methods ~w(GET POST DELETE)

  @doc false
  def api(conn, _params) do
    case allowed(conn) do
      [] -> Reply.error(conn, :not_found)
      methods -> conn |> put_resp_header("allow", methods) |> Reply.error(:method_not_allowed)
    end
  end

  @doc false
  def html(conn, _params) do
    case allowed(conn) do
      [] ->
        PageHTML.not_found(conn)

      methods ->
        conn
        |> put_resp_header("allow", methods)
        |> PageHTML.message(405, :not_found)
    end
  end

  # The methods the router serves for this path (the catch-all excluded).
  defp allowed(conn) do
    router = conn.private.phoenix_router

    @methods
    |> Enum.filter(fn method ->
      case Phoenix.Router.route_info(router, method, conn.path_info, conn.host) do
        %{route: route} -> not String.ends_with?(route, "/*path")
        :error -> false
      end
    end)
    |> Enum.join(", ")
    |> case do
      "" -> []
      methods -> methods
    end
  end
end
