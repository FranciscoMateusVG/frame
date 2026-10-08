defmodule Frame.Web.ErrorJSON do
  @moduledoc "Phoenix's `render_errors` view for JSON (see `Frame.Web.ErrorHTML`)."

  @doc false
  def render(template, _assigns),
    do: %{
      error: %{code: "INTERNAL", message: Phoenix.Controller.status_message_from_template(template)}
    }
end
