defmodule Frame.Web.Layouts do
  @moduledoc """
  The root layout of every HTML page. Scripts are same-origin files only
  (CSP `script-src 'self'`, no inline script): Phoenix and LiveView from
  their packages, plus `app.js`, which connects the LiveView socket with the
  masked CSRF token from the `csrf-token` meta tag (signed-in pages only).
  """

  use Frame.Web, :html

  @doc false
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="pt-BR">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <meta
          :if={assigns[:portal_session]}
          name="csrf-token"
          content={Plug.CSRFProtection.get_csrf_token()}
        />
        <.live_title suffix=" · Gráfica · Programa Incluir">
          {assigns[:page_title] || "Gráfica"}
        </.live_title>
        <link rel="stylesheet" href="/assets/app.css" />
        <script :if={assigns[:portal_session]} defer src="/assets/phoenix.min.js">
        </script>
        <script :if={assigns[:portal_session]} defer src="/assets/phoenix_live_view.min.js">
        </script>
        <script :if={assigns[:portal_session]} defer src="/assets/app.js">
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
