defmodule Frame.Web.BatchLive do
  @moduledoc """
  The batch screen (TTP task 1). Two routes:

    * `/` (`:current`) — the home page: the current batch (open, or active
      from collection until printed), or **Nenhum pedido aguardando**;
    * `/lotes/:id` (`:show`) — one batch of **Lotes anteriores**, read-only.

  The header shows the reference (`LOT-0001`), status, item count, total
  copies and the track **Pronto → Arquivos retirados → Orçamento enviado →
  Orçamento aprovado → Impresso**. Below, one card per FILE grouped under
  its request (`IMP-0001 · title`): name, size, copies, that file's
  instructions and **Baixar arquivo**; residual general instructions stay
  in their own request's block, never merged into a card.

  The one next action of the supplier, by status, each with an explicit
  confirmation:

    * open — checkbox **Conferi todos os arquivos** + **Retirei os
      arquivos** → **Confirmar retirada / Voltar**;
    * files_collected / quote_rejected — **Valor do orçamento** (BRL → cents)
      + **Arquivo do orçamento** (LiveView upload, 5 MB cap) + **Enviar
      orçamento** → **Confirmar envio / Voltar**; a rejection shows the reason;
    * quote_pending — **Aguardando aprovação do Financeiro**;
    * quote_approved — **Marcar como impresso** → **Confirmar impressão / Voltar**;
    * printed — **Aguardando recebimento**.

  Commands run over the socket through the use cases: If-Match = the ETag
  of the batch on screen, Idempotency-Key = the intent's key
  (`Frame.Web.Intent`). A 412 means the batch changed: the page re-reads it
  and asks for the confirmation again. When the upstream does not answer,
  nothing is reported as done: **Consultar novamente** re-reads the batch
  and **Repetir** sends the same command with the same key.

  The `data-ttp` markers are the common smoke contract of the three portals.
  """

  use Frame.Web, :live_view

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Domain.Batch
  alias Frame.Domain.Document
  alias Frame.Domain.Money
  alias Frame.Domain.Requests
  alias Frame.UseCases
  alias Frame.Web.Deps
  alias Frame.Web.Intent

  @done %{
    collect: "Retirada confirmada.",
    quote: "Orçamento enviado. Aguardando aprovação do Financeiro.",
    print: "Impressão confirmada."
  }

  @stale %{
    collect: "O lote foi atualizado. Confira os arquivos e confirme a retirada novamente.",
    quote: "O lote foi atualizado. Confira a situação atual antes de enviar o orçamento.",
    print: "O lote foi atualizado. Confira a situação atual antes de confirmar a impressão."
  }

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Lote atual",
        notice: nil,
        confirm: nil,
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

    socket =
      case {socket.assigns.live_action, Requests.uuid(params["id"])} do
        {:current, _} -> socket |> assign(:id, nil) |> load()
        {:show, {:ok, id}} -> socket |> assign(:id, id) |> load()
        {:show, :error} -> assign(socket, :result, :not_found)
      end

    # A plain request for a missing (or foreign) batch is a real 404.
    if socket.assigns.result == :not_found and not connected?(socket),
      do: raise(Frame.Web.NotFoundError),
      else: {:ok, socket}
  end

  # --- reading ---

  defp load(socket) do
    case read(socket) do
      {:ok, %Response{status: 200, body: %{"batch" => nil}}} ->
        assign(socket, result: :empty, pending: nil, confirm: nil)

      {:ok, %Response{status: 200, body: %{"batch" => batch}}} ->
        socket
        |> assign(result: :ok, batch: batch, etag: Batch.etag(batch))
        |> assign(:action, if(current?(socket), do: Batch.next_action(batch), else: :none))
        |> assign(:page_title, "Lote #{batch["reference"]}")
        |> keep_pending_if_still_due(batch)

      {:ok, %Response{status: 404}} ->
        assign(socket, result: :not_found, pending: nil, confirm: nil)

      _ ->
        assign(socket, :result, :unavailable)
    end
  end

  defp read(%{assigns: %{live_action: :current}} = socket),
    do: UseCases.GetCurrentBatch.get_current_batch(Deps.fetch(socket))

  defp read(socket), do: UseCases.GetBatch.get_batch(Deps.fetch(socket), socket.assigns.id)

  defp current?(socket), do: socket.assigns.live_action == :current

  # After "Consultar novamente": a command that did land is over.
  defp keep_pending_if_still_due(socket, batch) do
    case socket.assigns.pending do
      {action, _input, _pre} ->
        if due?(action, Batch.next_action(batch)),
          do: socket,
          else: assign(socket, pending: nil, key: Intent.new_key())

      nil ->
        socket
    end
  end

  defp due?(:collect, :collect), do: true
  defp due?(:quote, action), do: action in [:quote, :requote]
  defp due?(:print, :print), do: true
  defp due?(_action, _next), do: false

  # --- events ---

  @impl true
  def handle_event("collect", params, socket) do
    if params["conferi"] == "on",
      do: {:noreply, assign(socket, confirm: :collect, notice: nil)},
      else:
        {:noreply,
         notice(
           socket,
           {:error, "Marque “Conferi todos os arquivos” para confirmar a retirada."}
         )}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign_amount(socket, params["valor"] || "")}
  end

  def handle_event("quote", params, socket) do
    socket = assign_amount(socket, params["valor"] || "")

    cond do
      socket.assigns.amount_error ->
        {:noreply, socket}

      not upload_ready?(socket) ->
        {:noreply,
         notice(socket, {:error, "Escolha o arquivo do orçamento (PDF, JPEG, PNG ou WebP)."})}

      true ->
        {:noreply, assign(socket, confirm: :quote, notice: nil)}
    end
  end

  def handle_event("print", _params, socket),
    do: {:noreply, assign(socket, confirm: :print, notice: nil)}

  def handle_event("back", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :file, ref)}

  def handle_event("confirm", _params, socket) do
    with %{confirm: action, result: :ok, action: next} when action != nil <- socket.assigns,
         true <- due?(action, next),
         {:ok, input} <- command(socket, action) do
      {:noreply, run(socket, action, input, preconditions(socket))}
    else
      {:error, message} ->
        {:noreply, socket |> assign(:confirm, nil) |> notice({:error, message})}

      _ ->
        {:noreply, assign(socket, :confirm, nil)}
    end
  end

  def handle_event("repeat", _params, socket) do
    case socket.assigns.pending do
      {action, input, pre} -> {:noreply, run(socket, action, input, pre)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("refresh", _params, socket),
    do: {:noreply, socket |> assign(:notice, nil) |> load()}

  # --- commands ---

  defp preconditions(socket),
    do: %{if_match: socket.assigns.etag, idempotency_key: socket.assigns.key}

  defp command(_socket, :collect), do: {:ok, %{}}

  defp command(socket, :print) do
    case socket.assigns.batch["currentQuote"] do
      %{"id" => quote_id} -> {:ok, %{quote_id: quote_id}}
      _ -> {:error, Intent.message("INVALID_STATE")}
    end
  end

  defp command(socket, :quote) do
    with {:ok, cents} <- Money.parse_brl(socket.assigns.amount),
         [file] <-
           consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
             {:ok, %{name: entry.client_name, bytes: File.read!(path)}}
           end) do
      {:ok, %{amount_cents: cents, file: file}}
    else
      _ -> {:error, "Escolha o arquivo do orçamento e informe o valor de novo."}
    end
  end

  defp run(socket, action, input, pre) do
    socket = assign(socket, :confirm, nil)

    case execute(socket, action, input, pre) do
      # The batch changed since the page read it: never confirm a changed batch.
      {:ok, %Response{status: 412}} ->
        socket
        |> assign(pending: nil, key: Intent.new_key())
        |> load()
        |> notice({:stale, @stale[action]})

      result ->
        outcome(socket, action, input, pre, Intent.outcome(result))
    end
  end

  defp outcome(socket, action, input, pre, outcome) do
    case outcome do
      :done ->
        socket
        |> assign(pending: nil, key: Intent.new_key(), amount: "", amount_error: nil)
        |> load()
        |> notice({:ok, @done[action]})

      :unavailable ->
        socket
        |> assign(:pending, {action, input, pre})
        |> notice(:unavailable)

      :not_found ->
        socket |> assign(pending: nil, key: Intent.new_key()) |> load()

      {:refused, message, keep_key?} ->
        socket
        |> assign(pending: nil, key: if(keep_key?, do: pre.idempotency_key, else: Intent.new_key()))
        |> load()
        |> notice({:error, message})

      {:failed, message} ->
        socket |> assign(:pending, nil) |> notice({:error, message})
    end
  end

  defp execute(socket, :collect, _input, pre),
    do: UseCases.CollectBatch.collect_batch(Deps.fetch(socket), batch_id(socket), pre)

  defp execute(socket, :print, input, pre),
    do:
      UseCases.MarkBatchPrinted.mark_batch_printed(Deps.fetch(socket), batch_id(socket), input, pre)

  defp execute(socket, :quote, input, pre),
    do:
      UseCases.SubmitBatchQuote.submit_batch_quote(Deps.fetch(socket), batch_id(socket), input, pre)

  defp batch_id(socket), do: socket.assigns.batch["id"]

  # --- helpers ---

  defp notice(socket, notice), do: assign(socket, :notice, notice)

  defp assign_amount(socket, value) do
    error =
      case {String.trim(value), Money.parse_brl(value)} do
        {"", _} -> nil
        {_, {:ok, _}} -> nil
        _ -> "Informe o valor do orçamento em reais, por exemplo 459,90."
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

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp file_href(batch, item, file),
    do: "/api/print/v2/batches/#{batch["id"]}/orders/#{item["orderId"]}/files/#{file["id"]}"

  defp nav_current(:current), do: :batch
  defp nav_current(:show), do: :history

  # --- view ---

  @impl true
  def render(assigns) do
    ~H"""
    <.shell nav={%{csrf: @csrf, current: nav_current(@live_action)}}>
      <p :if={@live_action == :show} class="crumb">
        <.link navigate="/lotes">Voltar para Lotes anteriores</.link>
      </p>

      <%= case @result do %>
        <% :empty -> %>
          <section class="empty">
            <p class="empty__title" data-ttp="empty">Nenhum pedido aguardando</p>
            <p>Quando houver pedidos para imprimir, o lote aparece aqui.</p>
          </section>
        <% :not_found -> %>
          <.message
            title="Não encontrado"
            text="Este endereço não existe ou o lote não está disponível para a gráfica."
            link={{"/lotes", "Ir para Lotes anteriores"}}
          />
        <% :unavailable -> %>
          <.unavailable />
        <% :ok -> %>
          {batch(assigns)}
      <% end %>
    </.shell>
    """
  end

  defp unavailable(assigns) do
    ~H"""
    <section class="message" role="alert">
      <h1>Sem resposta do sistema do Incluir</h1>
      <p>Não foi possível consultar o lote agora.</p>
      <div class="actions">
        <button type="button" class="button button--primary" phx-click="refresh">
          Consultar novamente
        </button>
      </div>
    </section>
    """
  end

  defp batch(assigns) do
    ~H"""
    <article
      class="ticket"
      aria-labelledby="batch-ref"
      data-ttp="batch"
      data-batch-id={@batch["id"]}
      data-status={@batch["status"]}
    >
      <header class="ticket__head">
        <h1 id="batch-ref" class="ticket__ref" data-ttp="batch-reference">{@batch["reference"]}</h1>
        <p class="ticket__title">Lote de impressão</p>
        <dl class="facts">
          <div>
            <dt>Situação</dt>
            <dd>
              <span class={"status status--#{@batch["status"]}"}>{status_label(@batch["status"])}</span>
            </dd>
          </div>
          <div>
            <dt>Pedidos</dt><dd>{count(@batch["itemCount"], "pedido", "pedidos")}</dd>
          </div>
          <div>
            <dt>Arquivos</dt><dd>{count(Batch.file_count(@batch), "arquivo", "arquivos")}</dd>
          </div>
          <div>
            <dt>Cópias no total</dt><dd>{count(Batch.total_copies(@batch), "cópia", "cópias")}</dd>
          </div>
          <div>
            <dt>Criado em</dt><dd>{local_time(@batch["createdAt"])}</dd>
          </div>
          <div :if={@batch["collectedAt"]}>
            <dt>Retirado em</dt><dd>{local_time(@batch["collectedAt"])}</dd>
          </div>
          <div :if={@batch["printedAt"]}>
            <dt>Impresso em</dt><dd>{local_time(@batch["printedAt"])}</dd>
          </div>
          <div :if={@batch["receivedAt"]}>
            <dt>Recebido em</dt><dd>{local_time(@batch["receivedAt"])}</dd>
          </div>
          <div :if={@batch["approvedAmountCents"]}>
            <dt>Valor aprovado</dt><dd>{money(@batch["approvedAmountCents"])}</dd>
          </div>
        </dl>
      </header>

      <ol :if={@batch["status"] != "cancelled"} class="track" aria-label="Etapas do lote">
        <li
          :for={{label, state} <- Batch.steps(@batch)}
          class={"track__step track__step--#{state}"}
          aria-current={state == :current && "step"}
        >
          {label}
        </li>
      </ol>

      {notices(assigns)}

      <section :if={@live_action == :current} class="panel" aria-labelledby="panel-title">
        {next_action(assigns)}
      </section>

      <section :if={@batch["status"] == "cancelled"} class="panel" aria-labelledby="panel-title">
        <h2 id="panel-title">Lote cancelado</h2>
        <p><strong>Motivo:</strong> {@batch["cancellationReason"] || "não informado"}</p>
        <p>Os pedidos voltaram para o próximo lote. Descarte as cópias deste lote.</p>
      </section>

      <section class="jobs" aria-label="Pedidos e arquivos do lote">
        <section
          :for={item <- @batch["items"]}
          class="request"
          data-ttp="item"
          data-order-id={item["orderId"]}
          aria-labelledby={"item-#{item["orderId"]}"}
        >
          <h2 id={"item-#{item["orderId"]}"}>
            <span data-ttp="item-reference">{item["reference"]}</span> · {item["title"]}
          </h2>
          <p
            :if={item["previouslyCancelledIn"]}
            class="notice notice--warn"
            data-ttp="previously-cancelled"
          >
            Este item esteve no lote {item["previouslyCancelledIn"]}, cancelado — confira antes de imprimir
          </p>
          <ul class="jobs__list">
            <li
              :for={card <- Batch.cards(item)}
              class="job"
              data-ttp="file"
              data-file-id={card_file(card)["id"]}
            >
              <.file_card card={card} item={item} batch={@batch} />
            </li>
          </ul>
          <section
            :if={item["generalInstructions"]}
            class="general-instructions"
          >
            <h3>Instruções gerais</h3>
            <p>Instruções deste pedido sem vínculo seguro com um arquivo específico.</p>
            <pre class="general-instructions__text" data-ttp="general-instructions">{item["generalInstructions"]["text"]}</pre>
          </section>
        </section>
      </section>
    </article>
    """
  end

  defp card_file({:job, job}), do: job["file"]
  defp card_file({:residual, file}), do: file

  attr :card, :any, required: true, doc: "`{:job, job}` or `{:residual, file}`"
  attr :item, :map, required: true
  attr :batch, :map, required: true

  defp file_card(assigns) do
    assigns = assign(assigns, :file, card_file(assigns.card))

    ~H"""
    <%= case @card do %>
      <% {:job, job} -> %>
        <div class="job__head">
          <h3 class="job__title">{job["title"]}</h3>
          <p class="job__copies">
            <strong data-ttp="copies">{job["copies"]}</strong> {if job["copies"] == 1,
              do: "cópia",
              else: "cópias"}
          </p>
        </div>
        <p class="job__instructions" data-ttp="instructions">{job["instructions"]}</p>
      <% {:residual, _file} -> %>
        <div class="job__head">
          <h3 class="job__title">Não identificadas</h3>
        </div>
        <p class="job__instructions">Sem vínculo seguro — consulte instruções gerais</p>
    <% end %>
    <p class="job__file">
      <span class="job__filename" data-ttp="file-name">{@file["name"]}</span>
      <span class="job__size" data-ttp="file-size" data-bytes={@file["bytes"]}>
        {file_size(@file["bytes"])}
      </span>
      <a
        class="button button--small"
        data-ttp="download"
        href={file_href(@batch, @item, @file)}
        download
      >
        Baixar arquivo
      </a>
    </p>
    """
  end

  defp notices(%{notice: :unavailable} = assigns) do
    ~H"""
    <div class="notice notice--error" role="alert">
      <p>
        Sem resposta do sistema do Incluir. Não foi possível confirmar a operação agora: ela pode não ter sido registrada — ou pode ter chegado sem que a resposta voltasse.
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
    """
  end

  defp notices(%{notice: {:stale, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <div class="notice notice--warn" role="alert">
      <p>{@text}</p>
      <div class="actions">
        <button type="button" class="button" phx-click="refresh">Atualizar</button>
      </div>
    </div>
    """
  end

  defp notices(assigns) do
    ~H"""
    <.notice notice={@notice} />
    """
  end

  defp next_action(%{action: :collect} = assigns) do
    ~H"""
    <h2 id="panel-title">Retirada dos arquivos</h2>
    <p>
      Baixe e confira todos os arquivos do lote abaixo. Depois confirme a retirada — baixar sozinho não confirma nada.
    </p>
    <form id="collect-form" phx-submit="collect" class="stack">
      <label class="check">
        <input type="checkbox" name="conferi" value="on" required /> Conferi todos os arquivos
      </label>
      <div :if={@confirm != :collect} class="actions">
        <button
          type="submit"
          class="button button--primary"
          data-ttp="action"
          data-action="collect"
        >
          Retirei os arquivos
        </button>
      </div>
    </form>
    <.confirm
      :if={@confirm == :collect}
      id="confirm-collect"
      action="collect"
      title="Confirmar retirada"
      ok="Confirmar retirada"
    >
      Você confirma que retirou os {count(Batch.file_count(@batch), "arquivo", "arquivos")} dos {count(
        @batch["itemCount"],
        "pedido",
        "pedidos"
      )} do lote {@batch["reference"]}?
    </.confirm>
    """
  end

  defp next_action(%{action: action} = assigns) when action in [:quote, :requote] do
    ~H"""
    <%= if @action == :requote do %>
      <h2 id="panel-title">Orçamento rejeitado</h2>
      <p class="notice notice--error">
        <strong>Motivo do Financeiro:</strong> {@batch["currentQuote"]["rejectionReason"] ||
          "não informado"}
      </p>
      <p>Envie um novo orçamento para o lote inteiro. O anterior fica guardado no histórico.</p>
    <% else %>
      <h2 id="panel-title">Orçamento do lote</h2>
      <p>
        Informe o valor total do lote e anexe o orçamento (PDF, JPEG, PNG ou WebP, até 5 MB).
      </p>
    <% end %>
    <form id="quote-form" phx-change="validate" phx-submit="quote" class="stack">
      <label class="field">
        <span class="field__label">Valor do orçamento</span>
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
        <span class="field__label">Arquivo do orçamento</span>
        <.live_file_input upload={@uploads.file} required />
      </label>
      <.upload_state upload={@uploads.file} />
      <div :if={@confirm != :quote} class="actions">
        <button
          type="submit"
          class="button button--primary"
          data-ttp="action"
          data-action="upload-quote"
        >
          Enviar orçamento
        </button>
      </div>
    </form>
    <.confirm
      :if={@confirm == :quote}
      id="confirm-quote"
      action="quote"
      title="Confirmar envio"
      ok="Confirmar envio"
    >
      Enviar orçamento de <strong>{amount_label(@amount)}</strong>
      para o lote {@batch["reference"]} inteiro?
    </.confirm>
    """
  end

  defp next_action(%{action: :await_decision} = assigns) do
    ~H"""
    <h2 id="panel-title" data-ttp="status-message">Aguardando aprovação do Financeiro</h2>
    <p>
      Orçamento de <strong>{money(@batch["currentQuote"]["amountCents"])}</strong>
      enviado em {local_time(@batch["currentQuote"]["submittedAt"])}. Você será liberado para imprimir quando o Financeiro aprovar.
    </p>
    <p>
      <a
        class="button button--small"
        href={"/api/print/v2/batches/#{@batch["id"]}/quotes/#{@batch["currentQuote"]["id"]}/file"}
        download
      >
        Baixar orçamento
      </a>
    </p>
    """
  end

  defp next_action(%{action: :print} = assigns) do
    ~H"""
    <h2 id="panel-title">Orçamento aprovado</h2>
    <p>
      Valor aprovado: <strong>{money(@batch["currentQuote"]["amountCents"])}</strong>. Imprima o lote inteiro e depois confirme aqui.
    </p>
    <div :if={@confirm != :print} class="actions">
      <button
        type="button"
        class="button button--primary"
        phx-click="print"
        data-ttp="action"
        data-action="mark-printed"
      >
        Marcar como impresso
      </button>
    </div>
    <.confirm
      :if={@confirm == :print}
      id="confirm-print"
      action="print"
      title="Confirmar impressão"
      ok="Confirmar impressão"
    >
      Confirma que todo o lote {@batch["reference"]} foi impresso? Esta confirmação não pode ser desfeita pelo portal.
    </.confirm>
    """
  end

  defp next_action(%{action: :await_receipt} = assigns) do
    ~H"""
    <h2 id="panel-title" data-ttp="status-message">Aguardando recebimento</h2>
    <p>
      Impressão confirmada em {local_time(@batch["printedAt"])}. Valor aprovado: <strong>{money(@batch["approvedAmountCents"])}</strong>. O Financeiro confirma o recebimento do lote.
    </p>
    """
  end

  defp next_action(assigns) do
    ~H"""
    <h2 id="panel-title">Lote sem pedidos</h2>
    <p>Não há arquivos para retirar neste lote.</p>
    """
  end

  attr :upload, :any, required: true

  defp upload_state(assigns) do
    ~H"""
    <ul :if={@upload.entries != []} class="uploads">
      <li :for={entry <- @upload.entries} class="upload">
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
    <p :for={text <- upload_errors_text(@upload)} class="field__error" role="alert">{text}</p>
    """
  end

  attr :id, :string, required: true
  attr :action, :string, required: true, doc: "sent as `value.action` with the confirm event"
  attr :title, :string, required: true
  attr :ok, :string, required: true
  slot :inner_block, required: true

  defp confirm(assigns) do
    ~H"""
    <section
      id={@id}
      class="confirm confirm--inline"
      role="alertdialog"
      aria-labelledby={"#{@id}-title"}
    >
      <h3 id={"#{@id}-title"}>{@title}</h3>
      <p>{render_slot(@inner_block)}</p>
      <div class="actions">
        <button
          type="button"
          class="button button--primary"
          phx-click="confirm"
          phx-value-action={@action}
          phx-disable-with="Enviando…"
        >
          {@ok}
        </button>
        <button type="button" class="button" phx-click="back">Voltar</button>
      </div>
    </section>
    """
  end
end
