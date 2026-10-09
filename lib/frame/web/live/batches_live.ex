defmodule Frame.Web.BatchesLive do
  @moduledoc """
  **Lotes anteriores**: every batch of the supplier, history included, in
  the upstream's order (createdAt, id) — reference, status, dates and the
  approved amount, each opening its read-only detail (`/lotes/:id`, the
  same cards as the home page). **Próxima página** follows the upstream's
  opaque cursor.
  """

  use Frame.Web, :live_view

  alias Frame.Adapters.PrintApi.Response
  alias Frame.UseCases
  alias Frame.Web.Deps

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Lotes anteriores")}

  @impl true
  def handle_params(params, _uri, socket) do
    query =
      case params["cursor"] do
        cursor when is_binary(cursor) and byte_size(cursor) in 1..512 -> %{cursor: cursor}
        _ -> %{}
      end

    {:noreply, socket |> assign(:query, query) |> load()}
  end

  defp load(socket) do
    case UseCases.ListBatches.list_batches(Deps.fetch(socket), socket.assigns.query) do
      {:ok, %Response{status: 200, body: %{"items" => items, "nextCursor" => next}}} ->
        assign(socket, result: :ok, batches: items, next: next)

      {:ok, %Response{status: 400}} ->
        assign(socket, result: :ok, batches: [], next: nil)

      _ ->
        assign(socket, :result, :unavailable)
    end
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <.shell nav={%{csrf: @csrf, current: :history}}>
      <h1 class="heading">Lotes anteriores</h1>
      <%= case @result do %>
        <% :unavailable -> %>
          <section class="message" role="alert">
            <h2>Sem resposta do sistema do Incluir</h2>
            <p>Não foi possível consultar os lotes agora.</p>
            <div class="actions">
              <button type="button" class="button button--primary" phx-click="refresh">
                Consultar novamente
              </button>
            </div>
          </section>
        <% :ok -> %>
          <section :if={@batches == []} class="empty">
            <p class="empty__title">Nenhum lote ainda</p>
            <p>Os lotes aparecem aqui depois de formados.</p>
          </section>
          <table :if={@batches != []} class="orders">
            <thead>
              <tr>
                <th scope="col">Lote</th>
                <th scope="col">Situação</th>
                <th scope="col">Pedidos</th>
                <th scope="col">Criado em</th>
                <th scope="col">Impresso em</th>
                <th scope="col">Recebido em</th>
                <th scope="col" class="num">Valor aprovado</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={batch <- @batches}>
                <td class="orders__ref" data-label="Lote">
                  <.link navigate={"/lotes/#{batch["id"]}"}>{batch["reference"]}</.link>
                </td>
                <td data-label="Situação">
                  <span class={"status status--#{batch["status"]}"}>{status_label(batch["status"])}</span>
                </td>
                <td data-label="Pedidos">{batch["itemCount"]}</td>
                <td data-label="Criado em">{local_time(batch["createdAt"])}</td>
                <td data-label="Impresso em">{local_time(batch["printedAt"])}</td>
                <td data-label="Recebido em">{local_time(batch["receivedAt"])}</td>
                <td class="num" data-label="Valor aprovado">{money(batch["approvedAmountCents"])}</td>
              </tr>
            </tbody>
          </table>
          <nav :if={@next} class="pager" aria-label="Paginação">
            <.link patch={"/lotes?" <> URI.encode_query(cursor: @next)} class="button">
              Próxima página
            </.link>
          </nav>
      <% end %>
    </.shell>
    """
  end
end
