defmodule Frame.Http.HtmlEngine do
  @moduledoc """
  An EEx engine that HTML-escapes every `<%= %>` output by default (the
  same idea as Phoenix's engine, without the dependency). Trusted markup
  must be wrapped explicitly as `{:safe, iodata}` (see `safe/1`), so
  forgetting to escape supplier-controlled text is impossible by default.
  `@name` reads from the `assigns` map, as in `EEx.SmartEngine`.
  """

  @behaviour EEx.Engine

  @impl true
  defdelegate init(opts), to: EEx.Engine

  @impl true
  defdelegate handle_body(state), to: EEx.Engine

  @impl true
  defdelegate handle_text(state, meta, text), to: EEx.Engine

  @impl true
  defdelegate handle_begin(state), to: EEx.Engine

  # Inner blocks (`for`, `if`, ...) are template markup: mark them safe so
  # the enclosing `<%= %>` does not escape them again.
  @impl true
  def handle_end(state) do
    body = EEx.Engine.handle_end(state)
    quote(do: {:safe, unquote(body)})
  end

  @impl true
  def handle_expr(state, "=", ast) do
    ast = quote(do: unquote(__MODULE__).escape(unquote(assigns(ast))))
    EEx.Engine.handle_expr(state, "=", ast)
  end

  def handle_expr(state, marker, ast), do: EEx.Engine.handle_expr(state, marker, assigns(ast))

  @doc "Marks trusted markup so it is emitted verbatim."
  @spec safe(iodata()) :: {:safe, iodata()}
  def safe(iodata), do: {:safe, iodata}

  @doc "Escapes a value for HTML text and attribute contexts."
  @spec escape(term()) :: iodata()
  def escape({:safe, iodata}), do: iodata
  def escape(nil), do: ""
  def escape(list) when is_list(list), do: Enum.map(list, &escape/1)
  def escape(value) when is_binary(value), do: Plug.HTML.html_escape_to_iodata(value)
  def escape(value), do: value |> to_string() |> Plug.HTML.html_escape_to_iodata()

  defp assigns(ast) do
    Macro.prewalk(ast, fn
      {:@, meta, [{name, _, atom}]} when is_atom(name) and is_atom(atom) ->
        quote line: meta[:line] || 0 do
          Map.fetch!(var!(assigns), unquote(name))
        end

      other ->
        other
    end)
  end
end
