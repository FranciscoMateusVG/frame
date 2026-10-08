defmodule Frame.Domain.Requests do
  @moduledoc """
  Boundary parsers for everything the browser sends to the portal (the
  Elixir equivalent of Zod schemas). Called only at the HTTP edge.

  Rules from spec §4: unknown write fields are rejected; JSON bodies must be
  objects; integers are integers (no strings, floats or booleans); ids are
  UUIDs; nothing here echoes input back in an error.
  """

  alias Frame.Domain.Money
  alias Frame.Domain.Order

  @uuid ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
  @max_revision 1_000_000

  @typedoc "Order list filters, as forwarded upstream."
  @type list_query :: %{
          optional(:status) => String.t(),
          optional(:limit) => 1..100,
          optional(:cursor) => String.t()
        }

  @doc "A UUID path segment or header value."
  @spec uuid(term()) :: {:ok, String.t()} | :error
  def uuid(value) when is_binary(value) do
    if Regex.match?(@uuid, value), do: {:ok, value}, else: :error
  end

  def uuid(_value), do: :error

  @doc """
  A strong entity tag as the upstream issues it (`"<id>:<version>"`). Only
  its shape is checked; the upstream compares it.
  """
  @spec if_match(term()) :: {:ok, String.t()} | :error
  def if_match(value) when is_binary(value) do
    if Regex.match?(~r/^"[A-Za-z0-9:._-]{1,200}"$/, value), do: {:ok, value}, else: :error
  end

  def if_match(_value), do: :error

  @doc "`{password}` for `POST /api/session`."
  @spec login(term()) :: {:ok, String.t()} | :error
  def login(%{"password" => password} = body)
      when map_size(body) == 1 and is_binary(password) and byte_size(password) in 1..1024,
      do: {:ok, password}

  def login(_body), do: :error

  @doc "`{revision}` for `POST /orders/:id/collected`."
  @spec collected(term()) :: {:ok, %{revision: pos_integer()}} | :error
  def collected(%{"revision" => revision} = body) when map_size(body) == 1 do
    with {:ok, revision} <- revision(revision), do: {:ok, %{revision: revision}}
  end

  def collected(_body), do: :error

  @doc "`{revision, quoteId}` for `POST /orders/:id/printed`."
  @spec printed(term()) :: {:ok, %{revision: pos_integer(), quote_id: String.t()}} | :error
  def printed(%{"revision" => revision, "quoteId" => quote_id} = body)
      when map_size(body) == 2 do
    with {:ok, revision} <- revision(revision),
         {:ok, quote_id} <- uuid(quote_id) do
      {:ok, %{revision: revision, quote_id: quote_id}}
    end
  end

  def printed(_body), do: :error

  @doc "Query of `GET /orders` (unknown parameters are ignored)."
  @spec list_query(map()) :: {:ok, list_query()} | :error
  def list_query(%{} = params) do
    Enum.reduce_while([:status, :limit, :cursor], {:ok, %{}}, fn key, {:ok, acc} ->
      case list_param(key, Map.get(params, Atom.to_string(key))) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp list_param(_key, nil), do: :skip
  defp list_param(:status, ""), do: :skip
  defp list_param(:status, value), do: if(Order.status?(value), do: {:ok, value}, else: :error)

  defp list_param(:limit, value) when is_binary(value) do
    if Regex.match?(~r/^[1-9][0-9]{0,2}$/, value) and String.to_integer(value) <= 100,
      do: {:ok, String.to_integer(value)},
      else: :error
  end

  defp list_param(:cursor, value) when is_binary(value) and byte_size(value) in 1..512,
    do: {:ok, value}

  defp list_param(_key, _value), do: :error

  @doc "Multipart text fields of a quote upload: exactly `amountCents` and `orderRevision`."
  @spec quote_fields(map()) ::
          {:ok, %{amount_cents: Money.cents(), order_revision: pos_integer()}} | :error
  def quote_fields(%{"amountCents" => amount, "orderRevision" => revision} = fields)
      when map_size(fields) == 2 do
    with {:ok, cents} <- Money.parse_cents_string(amount),
         {:ok, revision} <- revision_string(revision) do
      {:ok, %{amount_cents: cents, order_revision: revision}}
    end
  end

  def quote_fields(_fields), do: :error

  @doc "Multipart text fields of an invoice upload: exactly `declaredTotalCents`."
  @spec invoice_fields(map()) :: {:ok, %{declared_total_cents: Money.cents()}} | :error
  def invoice_fields(%{"declaredTotalCents" => total} = fields) when map_size(fields) == 1 do
    with {:ok, cents} <- Money.parse_cents_string(total),
         do: {:ok, %{declared_total_cents: cents}}
  end

  def invoice_fields(_fields), do: :error

  @doc "A revision number given as a canonical integer string (HTML forms, multipart)."
  @spec revision_string(term()) :: {:ok, pos_integer()} | :error
  def revision_string(value) when is_binary(value) do
    if Regex.match?(~r/^[1-9][0-9]{0,6}$/, value),
      do: revision(String.to_integer(value)),
      else: :error
  end

  def revision_string(_value), do: :error

  defp revision(value) when is_integer(value) and value in 1..@max_revision, do: {:ok, value}
  defp revision(_value), do: :error
end
