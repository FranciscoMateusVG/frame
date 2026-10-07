defmodule Frame.Unit.LoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Frame.Observability.ConsoleLogger
  alias Frame.Observability.Logger
  alias Frame.Observability.NoopLogger

  describe "ConsoleLogger" do
    setup do
      %{logger: ConsoleLogger.new()}
    end

    test "info writes to stdout with formatted output", %{logger: logger} do
      output = capture_io(fn -> Logger.info(logger, "test message", %{key: "value"}) end)
      assert output =~ ~r/^\[.*\] INFO  test message {"key":"value"}\n$/
    end

    test "warn writes to stderr", %{logger: logger} do
      stderr =
        capture_io(:stderr, fn ->
          assert capture_io(fn -> Logger.warn(logger, "warning") end) == ""
        end)

      assert stderr =~ ~r/WARN/
    end

    test "error writes to stderr", %{logger: logger} do
      stderr =
        capture_io(:stderr, fn ->
          assert capture_io(fn -> Logger.error(logger, "failure") end) == ""
        end)

      assert stderr =~ ~r/ERROR/
    end

    test "debug writes to stdout", %{logger: logger} do
      assert capture_io(fn -> Logger.debug(logger, "detail") end) =~ ~r/DEBUG/
    end

    test "omits attrs when empty or undefined", %{logger: logger} do
      refute capture_io(fn -> Logger.info(logger, "no attrs") end) =~ "{"
      refute capture_io(fn -> Logger.info(logger, "empty attrs", %{}) end) =~ "{"
    end
  end

  describe "NoopLogger" do
    test "all functions execute without raising" do
      logger = NoopLogger.new()
      assert :ok = Logger.info(logger, "msg", %{a: 1})
      assert :ok = Logger.warn(logger, "msg")
      assert :ok = Logger.error(logger, "msg")
      assert :ok = Logger.debug(logger, "msg")
    end
  end
end
