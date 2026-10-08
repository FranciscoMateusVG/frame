defmodule Frame.Web.HealthController do
  @moduledoc """
  `GET /healthz` — liveness, no dependencies. `GET /readyz` — configured
  (we are running) and the upstream accepts the service token; the answer
  carries no content.
  """

  use Frame.Web, :controller

  alias Frame.Adapters.PrintApi.Response
  alias Frame.UseCases.ListOrders
  alias Frame.Web.Deps
  alias Frame.Web.Reply

  # Evaluated when compiling the release, not from the running container env.
  @revision (case System.get_env("BUILD_SHA") do
               nil -> "unknown"
               "" -> "unknown"
               revision -> revision
             end)

  @doc false
  def version(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> Reply.json(200, %{revision: @revision})
  end

  @doc false
  def live(conn, _params), do: conn |> put_resp_content_type("text/plain") |> send_resp(200, "ok")

  @doc false
  def ready(conn, _params) do
    case ListOrders.list_orders(Deps.fetch(conn), %{limit: 1}) do
      {:ok, %Response{status: 200}} -> Reply.json(conn, 200, %{ready: true})
      _ -> Reply.json(conn, 503, %{ready: false})
    end
  end
end
