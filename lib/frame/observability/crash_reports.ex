defmodule Frame.Observability.CrashReports do
  @moduledoc """
  A primary `:logger` filter that keeps crash reports content-free (spec
  §5 confidentiality).

  OTP and Elixir report a crashing process with its last message, its
  state, its process dictionary and the exception message — for a
  LiveView that is the order on screen (instructions, file names, amounts)
  and its session. This filter rewrites every such event (`crash_reason`
  metadata, or an OTP-domain report) into one fixed line naming only the
  exception *type*. Installed by the application at start.
  """

  @filter_id :frame_crash_reports

  @doc "Installs the filter (idempotent)."
  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
    end
  end

  @crash_labels [
    {:gen_server, :terminate},
    {:gen_statem, :terminate},
    {:gen_event, :terminate},
    {:proc_lib, :crash},
    {:supervisor, :child_terminated},
    {:supervisor, :start_error},
    {:supervisor, :shutdown_error}
  ]

  @doc false
  @spec filter(:logger.log_event(), term()) :: :logger.filter_return()
  def filter(%{meta: meta} = event, _args) do
    case crash_type(event) do
      nil ->
        :ignore

      type ->
        %{
          event
          | msg: {:string, "process terminated (#{type})"},
            meta: Map.drop(meta, [:crash_reason, :report_cb, :error_logger])
        }
    end
  end

  defp crash_type(%{meta: %{crash_reason: reason}}), do: type(reason)

  defp crash_type(%{msg: {:report, %{label: label} = report}}) when label in @crash_labels,
    do: report |> report_reason() |> type()

  defp crash_type(_event), do: nil

  defp report_reason(%{label: {:proc_lib, :crash}, report: [info | _]}) when is_list(info) do
    case info[:error_info] do
      {_class, reason, _stack} -> reason
      _ -> nil
    end
  end

  defp report_reason(%{label: {:supervisor, _}, report: info}) when is_list(info), do: info[:reason]
  defp report_reason(report), do: Map.get(report, :reason)

  defp type(exception) when is_exception(exception), do: inspect(exception.__struct__)
  defp type({exception, _stack}) when is_exception(exception), do: inspect(exception.__struct__)

  defp type({{exception, _stack}, _where}) when is_exception(exception),
    do: inspect(exception.__struct__)

  defp type({kind, _stack}) when is_atom(kind), do: Atom.to_string(kind)
  defp type(_other), do: "exit"
end
