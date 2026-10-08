defmodule Frame.Web do
  @moduledoc """
  The Phoenix edge of the portal: `use Frame.Web, :controller`,
  `:live_view` or `:html`.

  LiveViews are declared with `log: false`: LiveView's own logger prints
  params and the session at mount/event time, and both may carry content
  (amounts, the server session id). The portal logs one access line per
  request and business events from the use cases instead.
  """

  @doc false
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn
    end
  end

  @doc false
  def live_view do
    quote do
      use Phoenix.LiveView, log: false

      unquote(html_helpers())
    end
  end

  @doc false
  def html do
    quote do
      use Phoenix.Component

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML, only: [raw: 1]
      import Frame.Web.Components
    end
  end

  @doc "Dispatches to the appropriate `quote` block."
  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
