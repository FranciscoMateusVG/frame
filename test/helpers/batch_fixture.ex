defmodule Frame.Test.BatchFixture do
  @moduledoc """
  The frozen v2 batch fixture (`print-portal-v2.fixture.json`, copied from
  monorepo-incluir) and its synthetic PDF assets, read verbatim.

  `seed/2` puts batch DTOs (and the bytes of every file they reference)
  into a `PrintApi.Memory`, the way the staging fake serves them.
  """

  alias Frame.Adapters.PrintApi.Memory

  @dir Path.expand("../fixtures", __DIR__)
  @external_resource Path.join(@dir, "print-portal-v2.fixture.json")
  @fixture @dir |> Path.join("print-portal-v2.fixture.json") |> File.read!() |> JSON.decode!()

  @doc "The whole fixture document."
  def fixture, do: @fixture

  @doc "The snapshot of LOT-0001 in `status` (open … cancelled)."
  def batch(status), do: Enum.find(@fixture["batches"], &(&1["status"] == status))

  @doc "LOT-0003, formed by the whole-batch cancellation of LOT-0001."
  def rebatched, do: @fixture["rebatchedBatch"]["batch"]

  @doc "LOT-0002, exposed after LOT-0001 was received."
  def next_batch, do: @fixture["nextBatch"]["batch"]

  @doc "The mixed batch/legacy monthly close (2026-09)."
  def monthly_close, do: @fixture["monthlyClose"]["close"]

  @doc "The verbatim bytes of a fixture file id."
  def asset(file_id) do
    index = @dir |> Path.join("print-portal-v2.assets/index.json") |> File.read!() |> JSON.decode!()

    @dir
    |> Path.join("print-portal-v2.assets")
    |> Path.join(Map.fetch!(index, file_id))
    |> File.read!()
  end

  @doc "Every file of a batch (jobs first, then residual files, item by item)."
  def files(batch) do
    Enum.flat_map(batch["items"], fn item ->
      Enum.map(item["jobs"], & &1["file"]) ++
        (get_in(item, ["generalInstructions", "files"]) || [])
    end)
    |> Kernel.++(if q = batch["currentQuote"], do: [q["document"]], else: [])
  end

  @doc "Seeds `batches` (full DTOs) into `memory`, with the bytes of their files."
  def seed(memory, batches) do
    for batch <- List.wrap(batches) do
      blobs = Map.new(files(batch), &{&1["id"], {&1["name"], &1["mime"], asset(&1["id"])}})
      Memory.put_batch(memory, batch, blobs)
    end

    memory
  end
end
