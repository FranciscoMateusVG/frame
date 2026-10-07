defmodule Frame.Unit.CatRepositoryMemoryTest do
  # async: false — span assertions share the VM-wide SDK exporter.
  use ExUnit.Case, async: false

  alias Frame.Adapters.CatRepository.Memory
  alias Frame.Test.Observability, as: TestObs

  setup_all do
    test_obs = TestObs.create_test_observability()
    on_exit(fn -> TestObs.shutdown(test_obs) end)
    %{test_obs: test_obs}
  end

  # No reset_state needed — each factory call creates a fresh, empty Agent.
  use Frame.Test.CatRepositoryConformance,
    name: "Memory",
    factory: fn _context -> Memory.new() end,
    expected_db_system: "memory"
end
