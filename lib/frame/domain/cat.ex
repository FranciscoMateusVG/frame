defmodule Frame.Domain.Cat do
  @moduledoc """
  Cat entity, value objects, and boundary parsers. Pure data and pure
  functions — no I/O.

  The parsers (`parse_cat_id/1`, `parse_cat_name/1`,
  `parse_create_cat_input/1`) are the Elixir equivalent of the TypeScript
  Zod schemas (`CatIdSchema`, `CatNameSchema`, `CreateCatInputSchema`).
  They are called only at external boundaries (the use case entry point),
  never deeper in the domain.

  String semantics deliberately mirror the TypeScript reference
  (`String.prototype.trim` + `.length`, i.e. UTF-16 code units) so that
  every variant of Frame accepts and rejects exactly the same names. See
  `PARITY.md`.
  """

  # --- Value Objects ---

  @typedoc "Cat ID — a UUID string. Validated at external boundaries only."
  @type id :: String.t()

  @typedoc "Cat Name — non-empty, at most 100 characters after trimming."
  @type name :: String.t()

  # --- Entity ---

  @enforce_keys [:id, :name, :created_at]
  defstruct [:id, :name, :created_at]

  @typedoc "Cat entity — the core domain type. Pure data, no behaviour, no I/O."
  @type t :: %__MODULE__{id: id(), name: name(), created_at: DateTime.t()}

  # --- Input types ---

  @typedoc """
  Input for creating a new Cat. Validated at external boundaries before
  reaching use cases.

  The `id` is caller-provided (not server-generated) by design:

    * **Idempotency**: callers can safely retry with the same ID after
      failures. Duplicates are caught by the repository's unique constraint.
    * **Composability**: callers know the ID before persistence, enabling
      correlation IDs, related-entity setup, and outbox patterns.

  Generate IDs with `Ecto.UUID.generate/0`.
  """
  @type create_input :: %{id: id(), name: name()}

  @typedoc "A human-readable validation issue (one per failed check)."
  @type issue :: String.t()

  # Same pattern as Zod v4's `z.uuid()` (RFC 9562 variants + nil/max UUID).
  @uuid_regex ~r/^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$/

  # Exactly the code points removed by JavaScript's String.prototype.trim
  # (WhiteSpace + LineTerminator in ECMA-262).
  @js_whitespace "\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}" <>
                   "\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"
  @trim_regex Regex.compile!("^[#{@js_whitespace}]+|[#{@js_whitespace}]+$", "u")

  @name_max_length 100

  # JavaScript `typeof`-style names, for Zod-compatible type issues. Atoms
  # other than booleans have no JS counterpart; nil (and any atom) is "null".
  @js_types [
    {"boolean", &is_boolean/1},
    {"null", &is_atom/1},
    {"number", &is_number/1},
    {"string", &is_binary/1},
    {"array", &is_list/1}
  ]

  @doc "Validates a Cat ID (equivalent of `CatIdSchema`)."
  @spec parse_cat_id(term()) :: {:ok, id()} | {:error, [issue()]}
  def parse_cat_id(value) when is_binary(value) do
    if Regex.match?(@uuid_regex, value), do: {:ok, value}, else: {:error, ["Invalid UUID"]}
  end

  def parse_cat_id(value), do: {:error, [type_issue(value)]}

  @doc """
  Validates and normalizes a Cat name (equivalent of `CatNameSchema`):
  trims, then checks 1..100 characters.
  """
  @spec parse_cat_name(term()) :: {:ok, name()} | {:error, [issue()]}
  def parse_cat_name(value) when is_binary(value) do
    if String.valid?(value), do: check_name(trim_name(value)), else: {:error, [type_issue(value)]}
  end

  def parse_cat_name(value), do: {:error, [type_issue(value)]}

  defp check_name(trimmed) do
    case name_length(trimmed) do
      0 -> {:error, ["Cat name must not be empty"]}
      n when n > @name_max_length -> {:error, ["Cat name must be 100 characters or fewer"]}
      _ -> {:ok, trimmed}
    end
  end

  @doc """
  Validates a create-cat input map (equivalent of `CreateCatInputSchema`).
  Collects every issue, in field order (`id`, then `name`). Unknown keys are
  stripped.
  """
  @spec parse_create_cat_input(term()) :: {:ok, create_input()} | {:error, [issue()]}
  def parse_create_cat_input(%{} = input) when not is_struct(input) do
    id_result = parse_cat_id(Map.get(input, :id, :undefined))
    name_result = parse_cat_name(Map.get(input, :name, :undefined))

    case {id_result, name_result} do
      {{:ok, id}, {:ok, name}} -> {:ok, %{id: id, name: name}}
      _ -> {:error, issues(id_result) ++ issues(name_result)}
    end
  end

  def parse_create_cat_input(value), do: {:error, [type_issue(value, "object")]}

  @doc "Trims a name exactly like JavaScript's `String.prototype.trim`."
  @spec trim_name(String.t()) :: String.t()
  def trim_name(value), do: Regex.replace(@trim_regex, value, "")

  @doc "Length of a name as JavaScript measures it (UTF-16 code units)."
  @spec name_length(String.t()) :: non_neg_integer()
  def name_length(value) do
    value |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)
  end

  defp issues({:ok, _}), do: []
  defp issues({:error, issues}), do: issues

  defp type_issue(value, expected \\ "string") do
    "Invalid input: expected #{expected}, received #{js_type(value)}"
  end

  defp js_type(:undefined), do: "undefined"
  defp js_type(value), do: Enum.find_value(@js_types, "object", fn {t, t?} -> t?.(value) && t end)
end
