defmodule Frame.Web.NotFoundError do
  @moduledoc """
  Raised by a LiveView's disconnected mount when the resource does not
  exist (or is not the supplier's): `Frame.Web.Edge` answers the request
  with the 404 page. A connected LiveView shows the message in place.
  """

  defexception message: "not found", plug_status: 404
end
