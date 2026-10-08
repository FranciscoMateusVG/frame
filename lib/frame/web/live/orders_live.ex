defmodule Frame.Web.OrdersLive do
  @moduledoc """
  **Pedidos** (spec §7.4): the supplier's queue — status filter,
  **Atualizar**, keyset pagination (**Anterior / Próxima**), **Ver pedido**.
  New ready orders appear on the first load or on Atualizar (no push). An
  empty list ("Nenhum pedido") is distinct from an upstream failure
  ("Consultar novamente").

  The URL carries the state (`status`, `cursor`, `voltar` = the cursors
  behind), so links and reloads work and the page is shareable.
  """

  use Frame.Web, :live_view

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Domain.Requests
  alias Frame.UseCases.ListOrders
  alias Frame.Web.Deps

  @page_size 20

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Pedidos")}

  @impl true
  def handle_params(params, _uri, socket) do
    {query, back} =
      case Requests.list_query(Map.take(params, ["status", "cursor"])) do
        {:ok, query} -> {query, back_stack(params["voltar"])}
        :error -> {%{}, []}
      end

    {:noreply,
     socket
     |> assign(status: query[:status], cursor: query[:cursor], back: back)
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: orders_href(blank(status), nil, []))}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    query = %{limit: @page_size}
    query = if s = socket.assigns.status, do: Map.put(query, :status, s), else: query
    query = if c = socket.assigns.cursor, do: Map.put(query, :cursor, c), else: query

    result =
      case ListOrders.list_orders(Deps.fetch(socket), query) do
        {:ok, %Response{status: 200, body: body}} -> {:ok, body["items"], body["nextCursor"]}
        {:ok, %Response{body: %{"error" => %{"code" => "INVALID_CURSOR"}}}} -> :invalid_cursor
        _ -> :unavailable
      end

    assign(socket, :result, result)
  end

  defp blank(""), do: nil
  defp blank(value), do: value

  defp back_stack(nil), do: []

  defp back_stack(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.take(-20)
    |> Enum.filter(&(&1 == "-" or match?({:ok, _}, Requests.list_query(%{"cursor" => &1}))))
  end

  defp back_stack(_value), do: []

  @doc false
  def orders_href(status, cursor, back) do
    params =
      [{"status", status}, {"cursor", cursor}, {"voltar", if(back != [], do: Enum.join(back, ","))}]
      |> Enum.reject(fn {_k, v} -> v in [nil, "", "-"] end)

    if params == [], do: "/orders", else: "/orders?" <> URI.encode_query(params)
  end

  defp previous_href(_status, nil, _back), do: nil
  defp previous_href(status, _cursor, []), do: orders_href(status, nil, [])

  defp previous_href(status, _cursor, back) do
    {rest, [prev]} = Enum.split(back, -1)
    orders_href(status, if(prev == "-", do: nil, else: prev), rest)
  end

  defp next_href(_status, nil, _cursor, _back), do: nil
  defp next_href(status, next, cursor, back), do: orders_href(status, next, back ++ [cursor || "-"])

  @impl true
  def render(assigns) do
    ~H"""
    <.shell nav={%{csrf: @csrf, current: :orders}}>
      <section>
        <div class="heading">
          <h1>Pedidos</h1>
          <form
            id="orders-filter"
            method="get"
            action="/orders"
            class="filters"
            phx-change="filter"
            phx-submit="refresh"
          >
            <label class="field field--inline">
              <span class="field__label">Status</span>
              <select name="status">
                <option value="">Todos</option>
                <option :for={{value, label} <- statuses()} value={value} selected={value == @status}>
                  {label}
                </option>
              </select>
            </label>
            <button type="submit" class="button">Atualizar</button>
          </form>
        </div>

        <%= case @result do %>
          <% :unavailable -> %>
            <div class="notice notice--error" role="alert">
              <p>Não foi possível consultar os pedidos agora. O sistema do Incluir não respondeu.</p>
              <p>
                <button type="button" class="button" phx-click="refresh">Consultar novamente</button>
              </p>
            </div>
          <% :invalid_cursor -> %>
            <div class="notice notice--error" role="alert">
              <p>Esta página da lista não vale mais.</p>
              <p>
                <.link class="button" patch={orders_href(@status, nil, [])}>
                  Voltar ao início da lista
                </.link>
              </p>
            </div>
          <% {:ok, [], _next} -> %>
            <div class="empty">
              <p class="empty__title">
                Nenhum pedido{if @status, do: " com status “#{status_label(@status)}”"}.
              </p>
              <p>
                Pedidos aprovados pelo Financeiro aparecem aqui sozinhos. Use Atualizar para consultar de novo.
              </p>
            </div>
          <% {:ok, items, next} -> %>
            <table class="orders">
              <thead>
                <tr>
                  <th scope="col">Pedido</th>
                  <th scope="col">Título</th>
                  <th scope="col">Situação</th>
                  <th scope="col">Criado em</th>
                  <th scope="col"><span class="visually-hidden">Ação</span></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={o <- items} id={"order-#{o["id"]}"}>
                  <td class="orders__ref" data-label="Pedido">{o["reference"]}</td>
                  <td data-label="Título">{o["title"]}</td>
                  <td data-label="Situação">
                    <span class={"status status--#{o["status"]}"}>{status_label(o["status"])}</span>
                  </td>
                  <td data-label="Criado em">{local_time(o["createdAt"])}</td>
                  <td class="orders__action">
                    <.link class="button button--small" navigate={"/orders/#{o["id"]}"}>Ver pedido</.link>
                  </td>
                </tr>
              </tbody>
            </table>
            <nav class="pager" aria-label="Paginação">
              <%= if prev = previous_href(@status, @cursor, @back) do %>
                <.link class="button" patch={prev}>Anterior</.link>
              <% else %>
                <span class="button" aria-disabled="true">Anterior</span>
              <% end %>
              <%= if href = next_href(@status, next, @cursor, @back) do %>
                <.link class="button" patch={href}>Próxima</.link>
              <% else %>
                <span class="button" aria-disabled="true">Próxima</span>
              <% end %>
            </nav>
        <% end %>
      </section>
    </.shell>
    """
  end
end
