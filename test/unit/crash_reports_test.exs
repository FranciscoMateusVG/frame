defmodule Frame.Unit.CrashReportsTest do
  @moduledoc "Crash reports keep only the exception type (spec §5 confidentiality)."
  use ExUnit.Case, async: true

  alias Frame.Observability.CrashReports

  @secret "MARKER-estado-do-processo"

  defp event(msg, meta \\ %{}), do: %{level: :error, msg: msg, meta: Map.put(meta, :pid, self())}

  test "rewrites every crash shape to one fixed line with the type" do
    error = %RuntimeError{message: @secret}
    stack = [{M, :f, 1, []}]

    events = [
      event({:string, @secret}, %{crash_reason: {error, stack}}),
      event({:report, %{label: {:gen_server, :terminate}, reason: {error, stack}, state: @secret}}),
      event({:report, %{label: {:gen_server, :terminate}, reason: {{error, stack}, :where}}}),
      event(
        {:report,
         %{
           label: {:proc_lib, :crash},
           report: [[error_info: {:error, error, stack}, dictionary: [x: @secret]], []]
         }}
      ),
      event(
        {:report,
         %{label: {:supervisor, :child_terminated}, report: [reason: error, offender: [@secret]]}}
      )
    ]

    for e <- events do
      assert %{msg: {:string, "process terminated (RuntimeError)"}, meta: meta} =
               CrashReports.filter(e, [])

      refute Map.has_key?(meta, :crash_reason)
    end

    assert %{msg: {:string, "process terminated (exit)"}} =
             CrashReports.filter(
               event({:report, %{label: {:gen_server, :terminate}, reason: :killed}}),
               []
             )

    assert %{msg: {:string, "process terminated (throw)"}} =
             CrashReports.filter(event({:string, "x"}, %{crash_reason: {:throw, []}}), [])

    assert %{msg: {:string, "process terminated (exit)"}} =
             CrashReports.filter(
               event({:report, %{label: {:proc_lib, :crash}, report: [[], []]}}),
               []
             )
  end

  test "leaves everything else alone" do
    for e <- [
          event({:string, "http.request"}),
          event({:report, %{label: {:supervisor, :progress}, report: []}}),
          event({:report, %{message: "x"}})
        ],
        do: assert(CrashReports.filter(e, []) == :ignore)
  end

  test "install/0 is idempotent" do
    assert CrashReports.install() == :ok
    assert CrashReports.install() == :ok
  end
end
