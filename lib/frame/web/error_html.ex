defmodule Frame.Web.ErrorHTML do
  @moduledoc """
  Phoenix's `render_errors` view for HTML. `Frame.Web.Edge` answers every
  failure below the router itself; this only covers what Phoenix renders
  before it (fixed text, nothing from the request).
  """

  @doc false
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
