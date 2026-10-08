defmodule Frame.Web.Endpoint do
  @moduledoc """
  The portal's Phoenix endpoint (Bandit).

  Runtime configuration — port, URL, `check_origin` (exactly
  `PRINT_PORTAL_ORIGIN`), a `secret_key_base` random per boot and the
  dependency map (`:frame_deps`) — comes from the composition root's start
  arguments (`Frame.Application`), never from the application environment.

  The LiveView socket is the browser's command channel. It authenticates
  every connect against the server-side session (`Frame.Web.SessionCookieStore`
  reads `__Host-print_session`) and Phoenix verifies the masked CSRF token;
  a cross-site Origin is refused by `check_origin` and a missing one by
  `Frame.Web.OriginGuard`.
  """

  use Phoenix.Endpoint, otp_app: :frame

  alias Frame.Web.SessionCookieStore

  @before_compile Frame.Web.OriginGuard

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: SessionCookieStore.options()],
      # A LiveView upload chunk is 64 KiB; events are small forms.
      max_frame_size: 256 * 1024,
      compress: false
    ],
    longpoll: false

  plug Frame.Web.Edge
end
