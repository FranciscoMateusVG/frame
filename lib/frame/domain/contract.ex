defmodule Frame.Domain.Contract do
  @moduledoc """
  The frozen upstream response contract (`print-portal-v1.schema.json`,
  monorepo-incluir PR B + PR C), as strict validators over decoded JSON.

  Every 2xx body the portal receives from Hono is checked here before it is
  rendered or relayed: required keys, no additional keys, types, enums and
  ranges. A body that does not match is contract drift — the portal treats
  it as an unavailable upstream instead of showing or forwarding it.
  """

  @max_cents 2_147_483_647
  @max_safe 9_007_199_254_740_991

  @uuid ~r/^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$/
  @instant ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z$/
  @order_statuses ~w(ready files_collected quote_pending quote_rejected quote_approved printed cancelled)

  @type kind ::
          :order_list_response | :order_response | :close_response | :error_response

  @doc "Validates a decoded body against a response type of the contract."
  @spec validate(kind(), term()) :: :ok | {:error, String.t()}
  def validate(kind, body) do
    case check(spec(kind), body, "$") do
      [] -> :ok
      [first | _] -> {:error, first}
    end
  end

  # --- schema (one clause per $def) ---

  defp spec(:order_list_response),
    do:
      {:object, %{"items" => {:array, spec(:order_summary)}, "nextCursor" => {:nullable, :string}}}

  defp spec(:order_response), do: {:object, %{"order" => spec(:order)}}
  defp spec(:close_response), do: {:object, %{"close" => spec(:close)}}

  defp spec(:error_response) do
    {:object,
     %{
       "error" =>
         {:object, %{"code" => :nonempty_string, "message" => :string, "requestId" => :string}}
     }}
  end

  defp spec(:file) do
    {:object,
     %{
       "id" => :uuid,
       "name" => {:string, 1, 200},
       "mime" => :nonempty_string,
       "bytes" => {:integer, 1, @max_safe},
       "sha256" => {:pattern, ~r/^[0-9a-f]{64}$/}
     }}
  end

  defp spec(:print_job) do
    {:object,
     %{
       "id" => :uuid,
       "title" => {:string, 2, 160},
       "copies" => {:integer, 1, 500},
       "instructions" => {:string, 5, 4000},
       "file" => spec(:file)
     }}
  end

  defp spec(:quote) do
    {:object,
     %{
       "id" => :uuid,
       "revision" => {:integer, 1, @max_safe},
       "orderRevision" => {:integer, 1, @max_safe},
       "amountCents" => {:integer, 1, @max_cents},
       "currency" => {:enum, ["BRL"]},
       "document" => spec(:file),
       "decision" => {:enum, ~w(pending approved rejected)},
       "rejectionReason" => {:nullable, :string},
       "submittedAt" => :instant,
       "decidedAt" => {:nullable, :instant}
     }}
  end

  defp spec(:order_summary), do: {:object, summary_fields()}

  defp spec(:order) do
    {:object,
     Map.merge(summary_fields(), %{
       "jobs" => {:nonempty_array, spec(:print_job)},
       "currentQuote" => {:nullable, spec(:quote)},
       "cancellationReason" => {:nullable, :string}
     })}
  end

  defp spec(:close_item) do
    {:object,
     %{
       "orderId" => :uuid,
       "reference" => {:pattern, ~r/^IMP-\d{4,}$/},
       "quoteId" => :uuid,
       "amountCents" => {:integer, 1, @max_cents},
       "printedAt" => :instant
     }}
  end

  defp spec(:close) do
    {:object,
     %{
       "id" => {:nullable, :uuid},
       "competence" => {:pattern, ~r/^[0-9]{4}-(0[1-9]|1[0-2])$/},
       "version" => {:integer, 0, @max_safe},
       "state" => {:enum, ~w(open submitted rejected accepted)},
       "periodClosed" => :boolean,
       "items" => {:array, spec(:close_item)},
       "expectedTotalCents" => {:integer, 0, @max_cents},
       "declaredTotalCents" => {:nullable, {:integer, 1, @max_cents}},
       "document" => {:nullable, spec(:file)},
       "rejectionReason" => {:nullable, :string},
       "submittedAt" => {:nullable, :instant},
       "acceptedAt" => {:nullable, :instant}
     }}
  end

  defp summary_fields do
    %{
      "id" => :uuid,
      "reference" => {:pattern, ~r/^IMP-\d{4,}$/},
      "title" => :nonempty_string,
      "revision" => {:integer, 1, @max_safe},
      "version" => {:integer, 1, @max_safe},
      "status" => {:enum, @order_statuses},
      "createdAt" => :instant,
      "collectedAt" => {:nullable, :instant},
      "printedAt" => {:nullable, :instant},
      "approvedAmountCents" => {:nullable, {:integer, 1, @max_cents}}
    }
  end

  # --- checker: returns a list of problems (paths only, never values) ---

  defp check({:object, fields}, %{} = value, path) when not is_struct(value) do
    extra = for key <- Map.keys(value), not Map.has_key?(fields, key), do: "#{path}.#{key}: extra"

    missing =
      for {key, _} <- fields, not Map.has_key?(value, key), do: "#{path}.#{key}: missing"

    nested =
      for {key, field_spec} <- fields,
          Map.has_key?(value, key),
          problem <- check(field_spec, Map.fetch!(value, key), "#{path}.#{key}"),
          do: problem

    extra ++ missing ++ nested
  end

  defp check({:nullable, _inner}, nil, _path), do: []
  defp check({:nullable, inner}, value, path), do: check(inner, value, path)

  defp check({:array, item}, value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, i} -> check(item, v, "#{path}[#{i}]") end)
  end

  defp check({:nonempty_array, _item}, [], path), do: ["#{path}: empty"]
  defp check({:nonempty_array, item}, value, path), do: check({:array, item}, value, path)

  defp check(:string, value, _path) when is_binary(value), do: []
  defp check(:nonempty_string, value, path), do: check({:string, 1, nil}, value, path)

  defp check({:string, min, max}, value, path) when is_binary(value) do
    len = String.length(value)
    if len >= min and (max == nil or len <= max), do: [], else: ["#{path}: length"]
  end

  defp check({:integer, min, max}, value, path) when is_integer(value),
    do: if(value >= min and value <= max, do: [], else: ["#{path}: range"])

  defp check(:boolean, value, _path) when is_boolean(value), do: []

  defp check({:enum, allowed}, value, path),
    do: if(value in allowed, do: [], else: ["#{path}: enum"])

  defp check(:uuid, value, path), do: check({:pattern, @uuid}, value, path)
  defp check(:instant, value, path), do: check({:pattern, @instant}, value, path)

  defp check({:pattern, regex}, value, path) when is_binary(value),
    do: if(Regex.match?(regex, value), do: [], else: ["#{path}: format"])

  defp check(_spec, _value, path), do: ["#{path}: type"]
end
