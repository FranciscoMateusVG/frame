defmodule Frame.Web.LiveAuth do
  @moduledoc """
  `on_mount` of the supplier LiveViews. The server session must be alive
  at mount (disconnected and connected) and is re-checked — and touched,
  extending the idle window — before every event and patch: a session
  revoked or expired in the middle of a connection redirects to `/login`
  and the event never runs (spec §7.12: no false success).

  Assigns `:portal_session_id` (never rendered) and `:csrf` (the session's
  CSRF token, for the Sair form).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Frame.Adapters.SessionStore
  alias Frame.Web.Deps

  @doc false
  def on_mount(:default, _params, session, socket) do
    socket = Deps.put_live(socket)

    case fetch(socket, session["portal_session_id"]) do
      {:ok, portal_session} ->
        socket =
          socket
          |> assign(:portal_session_id, portal_session.id)
          |> assign(:csrf, portal_session.csrf_token)
          |> attach_hook(:portal_session, :handle_event, &check_event/3)
          |> attach_hook(:portal_session_params, :handle_params, &check_params/3)

        {:cont, socket}

      :error ->
        {:halt, redirect(socket, to: "/login")}
    end
  end

  defp check_event(_event, _params, socket), do: check(socket)
  defp check_params(_params, _uri, socket), do: check(socket)

  defp check(socket) do
    case fetch(socket, socket.assigns.portal_session_id) do
      {:ok, _} -> {:cont, socket}
      :error -> {:halt, redirect(socket, to: "/login")}
    end
  end

  defp fetch(_socket, nil), do: :error

  defp fetch(socket, id),
    do: SessionStore.fetch(Deps.fetch(socket).session_store, id, :authenticated)
end
