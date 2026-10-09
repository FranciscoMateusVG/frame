defmodule Frame.Web.InvoicesLive do
  @moduledoc """
  **Notas fiscais** (spec §7.9): one NF per month, on the v2 monthly close.
  **Competência** (the last twelve months; the previous one by default),
  the month's printed batches (each linking to its detail) and historical
  individual charges, each counted once, and the **Total calculado**; the current month explains when it
  closes. **Valor total da NF** + **Arquivo da NF** (LiveView upload, 5 MB
  cap) + **Enviar NF** → **Confirmar envio / Voltar**; then **Aguardando
  conferência**. A declared total that differs from the calculated one is
  highlighted, never "fixed".

  Commands follow `Frame.Web.Intent` (If-Match = the close's ETag, one
  Idempotency-Key per intent, **Repetir** with the same key after no
  answer). A Hono without monthly closes shows "ainda indisponíveis".
  """

  use Frame.Web, :live_view

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Domain.Close
  alias Frame.Domain.Competence
  alias Frame.Domain.Document
  alias Frame.Domain.Money
  alias Frame.UseCases
  alias Frame.Web.Deps
  alias Frame.Web.Intent

  @impl true
  def mount(_params, _session, socket) do
    current = Competence.containing(Deps.fetch(socket).clock.())

    socket =
      socket
      |> assign(
        page_title: "Notas fiscais",
        competences: Competence.recent(current, 12),
        current: current,
        notice: nil,
        confirm: false,
        pending: nil,
        key: Intent.new_key(),
        amount: "",
        amount_error: nil
      )
      |> allow_upload(:file,
        accept: ~w(.pdf .jpg .jpeg .png .webp),
        max_entries: 1,
        max_file_size: Document.max_bytes()
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    competence =
      case Competence.parse(params["competencia"]) do
        {:ok, c} -> c
        :error -> Competence.previous(socket.assigns.current)
      end

    changed? = Map.get(socket.assigns, :competence) not in [nil, competence]

    socket =
      if changed?,
        do: assign(socket, notice: nil, confirm: false, pending: nil, key: Intent.new_key()),
        else: socket

    {:noreply, socket |> assign(:competence, competence) |> load()}
  end

  defp load(socket) do
    key = Competence.to_string(socket.assigns.competence)

    result =
      case UseCases.GetBatchClose.get_batch_close(Deps.fetch(socket), key) do
        {:ok, %Response{status: 200, body: %{"close" => close}}} -> {:ok, close}
        {:ok, %Response{status: 404}} -> :not_available
        _ -> :unavailable
      end

    submission =
      case result do
        {:ok, close} -> Close.submission(close)
        _ -> nil
      end

    socket = assign(socket, result: result, submission: submission)

    # After "Consultar novamente": an NF that did land ends the intent.
    if socket.assigns.pending && submission != :ok,
      do: assign(socket, pending: nil, key: Intent.new_key()),
      else: socket
  end

  # --- events ---

  @impl true
  def handle_event("competence", %{"competencia" => value}, socket) do
    {:noreply, push_patch(socket, to: "/invoices?" <> URI.encode_query(competencia: value))}
  end

  def handle_event("validate", params, socket),
    do: {:noreply, assign_amount(socket, params["valor"] || "")}

  def handle_event("submit", params, socket) do
    socket = assign_amount(socket, params["valor"] || "")

    cond do
      socket.assigns.amount_error ->
        {:noreply, socket}

      not upload_ready?(socket) ->
        {:noreply, notice(socket, {:error, "Escolha o arquivo da NF (PDF, JPEG, PNG ou WebP)."})}

      true ->
        {:noreply, assign(socket, confirm: true, notice: nil)}
    end
  end

  def handle_event("back", _params, socket), do: {:noreply, assign(socket, :confirm, false)}

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :file, ref)}

  def handle_event("confirm", _params, socket) do
    with true <- socket.assigns.confirm,
         {:ok, close} <- socket.assigns.result,
         {:ok, input} <- command(socket) do
      pre = %{if_match: Close.etag(close), idempotency_key: socket.assigns.key}
      {:noreply, run(socket, input, pre)}
    else
      {:error, message} ->
        {:noreply, socket |> assign(:confirm, false) |> notice({:error, message})}

      _ ->
        {:noreply, assign(socket, :confirm, false)}
    end
  end

  def handle_event("repeat", _params, socket) do
    case socket.assigns.pending do
      {input, pre} -> {:noreply, run(socket, input, pre)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("refresh", _params, socket),
    do: {:noreply, socket |> assign(:notice, nil) |> load()}

  # --- the command ---

  defp command(socket) do
    with {:ok, cents} <- Money.parse_brl(socket.assigns.amount),
         [file] <-
           consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
             {:ok, %{name: entry.client_name, bytes: File.read!(path)}}
           end) do
      {:ok, %{declared_total_cents: cents, file: file}}
    else
      _ -> {:error, "Escolha o arquivo da NF e informe o valor de novo."}
    end
  end

  defp run(socket, input, pre) do
    socket = assign(socket, :confirm, false)
    competence = Competence.to_string(socket.assigns.competence)

    result =
      UseCases.SubmitBatchInvoice.submit_batch_invoice(Deps.fetch(socket), competence, input, pre)

    case Intent.outcome(result) do
      :done ->
        socket
        |> assign(pending: nil, key: Intent.new_key(), amount: "", amount_error: nil)
        |> load()
        |> notice({:ok, "NF enviada. Aguardando conferência do Financeiro."})

      :unavailable ->
        socket |> assign(:pending, {input, pre}) |> notice(:unavailable)

      {:refused, message, keep_key?} ->
        socket
        |> assign(pending: nil, key: if(keep_key?, do: pre.idempotency_key, else: Intent.new_key()))
        |> load()
        |> notice({:error, message})

      :not_found ->
        socket |> assign(:pending, nil) |> load()

      {:failed, message} ->
        socket |> assign(:pending, nil) |> notice({:error, message})
    end
  end

  # --- helpers ---

  defp notice(socket, notice), do: assign(socket, :notice, notice)

  defp assign_amount(socket, value) do
    error =
      case {String.trim(value), Money.parse_brl(value)} do
        {"", _} -> nil
        {_, {:ok, _}} -> nil
        _ -> "Informe o valor total da NF em reais, por exemplo 579,00."
      end

    assign(socket, amount: value, amount_error: error)
  end

  defp upload_ready?(socket) do
    case socket.assigns.uploads.file.entries do
      [entry] -> entry.valid? and entry.done?
      _ -> false
    end
  end

  defp amount_label(amount) do
    case Money.parse_brl(amount) do
      {:ok, cents} -> Money.format_brl(cents)
      _ -> "—"
    end
  end

  defp upload_errors_text(upload) do
    for error <- upload_errors(upload) ++ Enum.flat_map(upload.entries, &upload_errors(upload, &1)),
        uniq: true,
        do: Intent.upload_error(error)
  end

  # --- view ---

  @impl true
  def render(assigns) do
    ~H"""
    <.shell nav={%{csrf: @csrf, current: :invoices}}>
      <section>
        <div class="heading">
          <h1>Notas fiscais</h1>
          <form
            id="competence-form"
            method="get"
            action="/invoices"
            class="filters"
            phx-change="competence"
            phx-submit="refresh"
          >
            <label class="field field--inline">
              <span class="field__label">Competência</span>
              <select name="competencia">
                <option
                  :for={c <- @competences}
                  value={competence_value(c)}
                  selected={c == @competence}
                >
                  {competence_label(c)}
                </option>
              </select>
            </label>
            <button type="submit" class="button">Consultar</button>
          </form>
        </div>

        <p class="lede">
          Uma NF por mês, com todos os pedidos impressos naquele mês. A NF de {competence_label(
            @competence
          )} pode ser enviada a partir de {opens_on(@competence)}.
        </p>

        <%= if @notice == :unavailable do %>
          <div class="notice notice--error" role="alert">
            <p>
              Sem resposta do sistema do Incluir. Não foi possível confirmar o envio da NF agora: ele pode não ter sido registrado — ou pode ter chegado sem que a resposta voltasse.
            </p>
            <p>
              Consulte a situação antes de repetir. Se repetir, a mesma confirmação é reenviada e não é registrada duas vezes.
            </p>
            <div class="actions">
              <button type="button" class="button button--primary" phx-click="refresh">
                Consultar novamente
              </button>
              <button :if={@pending} type="button" class="button" phx-click="repeat">Repetir</button>
            </div>
          </div>
        <% else %>
          <.notice notice={@notice} />
        <% end %>

        <%= case @result do %>
          <% :not_available -> %>
            <div class="empty">
              <p class="empty__title">Notas fiscais ainda indisponíveis.</p>
              <p>
                O envio de NF pelo portal ainda não foi liberado pelo Incluir. Os pedidos continuam funcionando normalmente.
              </p>
            </div>
          <% :unavailable -> %>
            <div class="notice notice--error" role="alert">
              <p>Não foi possível consultar o fechamento agora. O sistema do Incluir não respondeu.</p>
              <p>
                <button type="button" class="button" phx-click="refresh">Consultar novamente</button>
              </p>
            </div>
          <% {:ok, close} -> %>
            {close(assign(assigns, :close, close))}
        <% end %>
      </section>
    </.shell>
    """
  end

  defp close(assigns) do
    ~H"""
    <div class="close">
      <dl class="facts">
        <div>
          <dt>Competência</dt><dd>{competence_label(@competence)}</dd>
        </div>
        <div>
          <dt>Situação</dt>
          <dd>
            <span class={"status status--close-#{@close["state"]}"}>{close_label(@close["state"])}</span>
          </dd>
        </div>
        <div>
          <dt>Total calculado</dt><dd class="amount">{money(@close["expectedTotalCents"])}</dd>
        </div>
        <div :if={@close["declaredTotalCents"]}>
          <dt>Valor total da NF</dt>
          <dd class={["amount", Close.divergent?(@close) && "amount--diverges"]}>
            {money(@close["declaredTotalCents"])}
          </dd>
        </div>
      </dl>

      <p :if={Close.divergent?(@close)} class="notice notice--warn">
        O valor declarado na NF é diferente do total calculado pelos orçamentos aprovados. O Financeiro só aceita a NF com o mesmo valor.
      </p>

      <%= if @close["items"] == [] do %>
        <div class="empty">
          <p class="empty__title">Nenhum pedido impresso em {competence_label(@competence)}.</p>
        </div>
      <% else %>
        <table class="orders">
          <thead>
            <tr>
              <th scope="col">Lote ou pedido</th>
              <th scope="col">Impresso em</th>
              <th scope="col" class="num">Orçamento aprovado</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={item <- @close["items"]}>
              <td class="orders__ref" data-label="Lote ou pedido">
                <.link :if={item["kind"] == "batch"} navigate={"/lotes/#{item["batchId"]}"}>
                  {item["reference"]}
                </.link>
                <span :if={item["kind"] != "batch"}>{item["reference"]}</span>
              </td>
              <td data-label="Impresso em">{local_time(item["printedAt"])}</td>
              <td class="num" data-label="Orçamento aprovado">{money(item["amountCents"])}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr>
              <th scope="row" colspan="2">Total calculado</th>
              <td class="num">{money(@close["expectedTotalCents"])}</td>
            </tr>
          </tfoot>
        </table>
      <% end %>

      <p :if={@close["document"]} class="job__file">
        <span class="job__filename">{@close["document"]["name"]}</span>
        <span class="job__size">{file_size(@close["document"]["bytes"])}</span>
        <a
          class="button button--small"
          href={"/api/print/v2/monthly-closes/#{@close["competence"]}/invoice"}
          download
        >
          Baixar NF enviada
        </a>
      </p>

      <%= case @submission do %>
        <% :period_open -> %>
          <p class="notice notice--warn">
            O mês ainda não terminou. O envio da NF abre em {opens_on(@competence)}.
          </p>
        <% :already_submitted -> %>
          <p class="notice notice--wait">
            Aguardando conferência do Financeiro. Enviada em {local_time(@close["submittedAt"])}.
          </p>
        <% :accepted -> %>
          <p class="notice notice--ok">
            NF aceita pelo Financeiro em {local_time(@close["acceptedAt"])}.
          </p>
        <% :ok -> %>
          <p :if={@close["state"] == "rejected"} class="notice notice--error">
            <strong>NF rejeitada.</strong>
            Motivo: {@close["rejectionReason"] || "não informado"}. Envie uma nova NF.
          </p>
          <form id="nf-form" phx-change="validate" phx-submit="submit" class="stack panel">
            <h2>Enviar NF de {competence_label(@competence)}</h2>
            <label class="field">
              <span class="field__label">Valor total da NF</span>
              <span class="money">
                <span class="money__prefix" aria-hidden="true">R$</span><input
                  type="text"
                  name="valor"
                  inputmode="decimal"
                  autocomplete="off"
                  placeholder="0,00"
                  value={@amount}
                  aria-invalid={@amount_error && "true"}
                  required
                />
              </span>
            </label>
            <p :if={@amount_error} class="field__error" role="alert">{@amount_error}</p>
            <label class="field">
              <span class="field__label">Arquivo da NF</span>
              <.live_file_input upload={@uploads.file} required />
            </label>
            <ul :if={@uploads.file.entries != []} class="uploads">
              <li :for={entry <- @uploads.file.entries} class="upload">
                <span class="job__filename">{entry.client_name}</span>
                <span class="job__size">{entry.progress}%</span>
                <button
                  type="button"
                  class="link-button"
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                  aria-label="Remover arquivo"
                >
                  Remover
                </button>
              </li>
            </ul>
            <p :for={text <- upload_errors_text(@uploads.file)} class="field__error" role="alert">
              {text}
            </p>
            <div :if={!@confirm} class="actions">
              <button type="submit" class="button button--primary">Enviar NF</button>
            </div>
          </form>
          <section
            :if={@confirm}
            id="confirm-nf"
            class="confirm confirm--inline"
            role="alertdialog"
            aria-labelledby="confirm-nf-title"
          >
            <h3 id="confirm-nf-title">Confirmar envio</h3>
            <p>
              Enviar a NF de {competence_label(@competence)} com valor total de <strong>{amount_label(@amount)}</strong>? O total calculado é {money(
                @close["expectedTotalCents"]
              )}.
            </p>
            <div class="actions">
              <button
                type="button"
                class="button button--primary"
                phx-click="confirm"
                phx-value-action="invoice"
                phx-disable-with="Enviando…"
              >
                Confirmar envio
              </button>
              <button type="button" class="button" phx-click="back">Voltar</button>
            </div>
          </section>
        <% _ -> %>
      <% end %>
    </div>
    """
  end
end
