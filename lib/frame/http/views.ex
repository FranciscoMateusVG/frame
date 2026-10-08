defmodule Frame.Http.Views do
  @moduledoc """
  HTML views: EEx templates in `templates/`, compiled with the
  auto-escaping `Frame.Http.HtmlEngine`, plus the small formatting helpers
  they use (money, São Paulo times, labels).
  """

  require EEx

  alias Frame.Domain.Close
  alias Frame.Domain.Competence
  alias Frame.Domain.Money
  alias Frame.Domain.Order
  alias Frame.Http.HtmlEngine

  @templates Path.join(__DIR__, "templates")

  for name <- ~w(layout login orders order invoices retry message) do
    path = Path.join(@templates, "#{name}.html.eex")
    @external_resource path
    EEx.function_from_file(:defp, :"render_#{name}", path, [:assigns], engine: HtmlEngine)
  end

  @doc "Login page."
  @spec login(map()) :: iodata()
  def login(assigns), do: layout("Entrar", nil, render_login(assigns))

  @doc "Orders list."
  @spec orders(map()) :: iodata()
  def orders(assigns), do: layout("Pedidos", assigns.nav, render_orders(assigns))

  @doc "Order detail (the work ticket)."
  @spec order(map()) :: iodata()
  def order(assigns),
    do: layout("Pedido #{assigns.order["reference"]}", assigns.nav, render_order(assigns))

  @doc "Monthly invoices."
  @spec invoices(map()) :: iodata()
  def invoices(assigns), do: layout("Notas fiscais", assigns.nav, render_invoices(assigns))

  @doc "Upstream did not answer: nothing confirmed; consult again or repeat."
  @spec retry(map()) :: iodata()
  def retry(assigns), do: layout("Sem resposta", assigns.nav, render_retry(assigns))

  @doc "404 page."
  @spec not_found(map() | nil) :: iodata()
  def not_found(nav) do
    layout(
      "Não encontrado",
      nav,
      render_message(%{
        title: "Não encontrado",
        text: "Este endereço não existe ou o pedido não está disponível para a gráfica.",
        link: {"/orders", "Ir para Pedidos"}
      })
    )
  end

  @doc "403 page (Origin/CSRF refused)."
  @spec forbidden() :: iodata()
  def forbidden do
    layout(
      "Requisição recusada",
      nil,
      render_message(%{
        title: "Requisição recusada",
        text:
          "A página expirou ou veio de outro endereço. Volte, recarregue a página e tente de novo.",
        link: {"/orders", "Recarregar Pedidos"}
      })
    )
  end

  defp layout(title, nav, body) do
    render_layout(%{title: title, nav: nav, body: HtmlEngine.safe(body)})
  end

  # --- helpers used by the templates ---

  @doc false
  def money(nil), do: "—"
  def money(cents), do: Money.format_brl(cents)

  @doc false
  def status_label(status), do: Order.status_label(status)

  @doc false
  def close_label(state), do: Close.state_label(state)

  @doc false
  def competence_label(%Competence{} = c), do: Competence.label(c)

  @doc false
  def competence_value(%Competence{} = c), do: Competence.to_string(c)

  @doc "An RFC 3339 instant shown as São Paulo local time (`08/10/2026 21:25`)."
  def local_time(nil), do: "—"

  def local_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        local = DateTime.add(dt, -3 * 3600, :second)
        Calendar.strftime(local, "%d/%m/%Y %H:%M")

      _ ->
        "—"
    end
  end

  @doc false
  def local_date(%Date{} = d), do: Calendar.strftime(d, "%d/%m/%Y")

  @doc false
  def file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  def file_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB" |> comma()
  def file_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB" |> comma()

  defp comma(text), do: String.replace(text, ".", ",")

  @doc false
  def next_action(order), do: Order.next_action(order)

  @doc false
  def total_copies(order), do: Order.total_copies(order)

  @doc false
  def divergent?(close), do: Close.divergent?(close)

  @doc false
  def opens_on(%Competence{} = c), do: local_date(Competence.opens_on(c))

  @steps [
    {"ready", "Pronto"},
    {"files_collected", "Arquivos retirados"},
    {"quote_pending", "Orçamento enviado"},
    {"quote_approved", "Orçamento aprovado"},
    {"printed", "Impresso"}
  ]

  @doc "The workflow track: `[{label, :done | :current | :todo}]`."
  def steps(%{"status" => status}) do
    status = if status == "quote_rejected", do: "quote_pending", else: status
    index = Enum.find_index(@steps, fn {s, _} -> s == status end)

    @steps
    |> Enum.with_index()
    |> Enum.map(fn {{_s, label}, i} ->
      cond do
        index == nil -> {label, :todo}
        i < index -> {label, :done}
        i == index and status == "printed" -> {label, :done}
        i == index -> {label, :current}
        true -> {label, :todo}
      end
    end)
  end

  @doc false
  def orders_href(status, cursor, back) do
    params =
      [{"status", status}, {"cursor", cursor}, {"voltar", if(back != [], do: Enum.join(back, ","))}]
      |> Enum.reject(fn {_k, v} -> v in [nil, "", "-"] end)

    if params == [], do: "/orders", else: "/orders?" <> URI.encode_query(params)
  end

  @doc "Link to the previous page of the keyset listing (`nil` on the first page)."
  def previous_href(_status, nil, _back), do: nil
  def previous_href(status, _cursor, []), do: orders_href(status, nil, [])

  def previous_href(status, _cursor, back) do
    {rest, [prev]} = Enum.split(back, -1)
    orders_href(status, if(prev == "-", do: nil, else: prev), rest)
  end

  @doc false
  def next_href(_status, nil, _cursor, _back), do: nil

  def next_href(status, next, cursor, back),
    do: orders_href(status, next, back ++ [cursor || "-"])

  @doc false
  def statuses, do: Enum.map(Order.statuses(), &{&1, Order.status_label(&1)})
end
