defmodule Frame.Web.LiveTelemetry do
  @moduledoc """
  One server span per LiveView callback — `mount`, `handle_params` and
  `handle_event` — from LiveView's telemetry events, so the use-case and
  adapter spans of a socket command nest under it the way they nest under
  the HTTP request span of `Frame.Web.Edge`.

  Spans are named `live <View> <callback>` and carry the view and, for
  events, the event name when it is one the pages define (a client can send
  any name; unknown ones are recorded as `other`). Never params, the
  session or assigns. An exception is recorded as its type only.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @events [:mount, :handle_params, :handle_event]
  @known ~w(filter refresh collect validate quote print back cancel-upload confirm repeat competence submit)
  @handler __MODULE__

  @doc "Attaches the handlers (idempotent)."
  @spec attach() :: :ok
  def attach do
    names =
      for event <- @events,
          suffix <- [:start, :stop, :exception],
          do: [:phoenix, :live_view, event, suffix]

    case :telemetry.attach_many(@handler, names, &__MODULE__.handle/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle([:phoenix, :live_view, callback, :start], _measurements, metadata, _config) do
    view = inspect(metadata.socket.view)

    attributes =
      %{"live.view": view, "live.callback": Atom.to_string(callback)}
      |> put_event(metadata)

    parent = Tracer.current_span_ctx()
    span = Tracer.start_span("live #{view} #{callback}", %{kind: :server, attributes: attributes})
    Tracer.set_current_span(span)
    Process.put({@handler, metadata.telemetry_span_context}, {span, parent})
  end

  def handle([:phoenix, :live_view, _callback, :stop], _measurements, metadata, _config) do
    finish(metadata, nil)
  end

  def handle([:phoenix, :live_view, _callback, :exception], _measurements, metadata, _config) do
    finish(metadata, metadata[:reason])
  end

  defp put_event(attributes, %{event: event}) when is_binary(event),
    do: Map.put(attributes, :"live.event", if(event in @known, do: event, else: "other"))

  defp put_event(attributes, _metadata), do: attributes

  defp finish(metadata, reason) do
    case Process.delete({@handler, metadata.telemetry_span_context}) do
      {span, parent} ->
        if reason do
          OpenTelemetry.Span.set_attribute(span, :"error.type", type(reason))
          OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, "exception"))
        end

        OpenTelemetry.Span.end_span(span)
        Tracer.set_current_span(parent)

      nil ->
        :ok
    end
  end

  defp type(reason) when is_exception(reason), do: inspect(reason.__struct__)
  defp type(_reason), do: "exit"
end
