defmodule Frame.Web.OrderLive do
  @moduledoc """
  **Ver pedido** (spec §7.5–§7.8): the work ticket — reference, revision,
  each job's title / copies / instructions with **Baixar arquivo** — and the
  one next action of the supplier:

    * collect — checkbox **Conferi todos os arquivos desta revisão** +
      **Arquivos retirados** → **Confirmar retirada / Voltar**;
    * quote — **Valor do orçamento** (BRL → cents, validated as typed) +
      **Arquivo do orçamento** (LiveView upload, 5 MB cap) + **Enviar
      orçamento** → **Confirmar envio / Voltar**; a rejection shows the reason
      and **Enviar novo orçamento**;
    * print — **Marcar como impresso** → **Confirmar impressão / Voltar**.

  Commands run here, over the socket, through the same use cases as the
  JSON API: If-Match = the ETag of the order on screen, Idempotency-Key =
  the intent's key (`Frame.Web.Intent`). When the upstream does not answer,
  nothing is reported as done: **Consultar novamente** re-reads the order
  and **Repetir** sends the same command with the same key.
  """

  use Frame.Web, :live_view

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Domain.Document
  alias Frame.Domain.Money
  alias Frame.Domain.Order
  alias Frame.Domain.Requests
  alias Frame.UseCases
  alias Frame.Web.Deps
  alias Frame.Web.Intent

  @done %{
    collect: "Retirada confirmada.",
    quote: "Orçamento enviado. Aguardando aprovação do Financeiro.",
    print: "Impressão confirmada."
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Pedido",
        id: id,
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
      case Requests.uuid(id) do
        {:ok, id} -> socket |> assign(:id, id) |> load()
        :error -> assign(socket, :result, :not_found)
      end

    # A plain request for a missing (or foreign) order is a real 404.
    if socket.assigns.result == :not_found and not connected?(socket),
      do: raise(Frame.Web.NotFoundError),
      else: {:ok, socket}
  end

  # --- reading ---

  defp load(socket) do
    case UseCases.GetOrder.get_order(Deps.fetch(socket), socket.assigns.id) do
      {:ok, %Response{status: 200, body: %{"order" => order}}} ->
        socket
        |> assign(result: :ok, order: order, etag: Order.etag(order))
        |> assign(:action, Order.next_action(order))
        |> assign(:page_title, "Pedido #{order["reference"]}")
        |> keep_pending_if_still_due(order)

      {:ok, %Response{status: 404}} ->
        assign(socket, result: :not_found, pending: nil, confirm: nil)

      _ ->
        assign(socket, :result, :unavailable)
    end
  end

  # After "Consultar novamente": a command that did land is over.
  defp keep_pending_if_still_due(socket, order) do
    case socket.assigns.pending do
      {action, _input, _pre} ->
        if due?(action, Order.next_action(order)),
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
           {:error, "Marque “Conferi todos os arquivos desta revisão” para confirmar a retirada."}
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
    case socket.assigns do
      %{confirm: action, result: :ok} when action in [:collect, :quote, :print] ->
        case command(socket, action) do
          {:ok, input} ->
            {:noreply, run(socket, action, input, preconditions(socket))}

          {:error, message} ->
            {:noreply, socket |> assign(:confirm, nil) |> notice({:error, message})}
        end

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

  defp command(socket, :collect), do: {:ok, %{revision: socket.assigns.order["revision"]}}

  defp command(socket, :print) do
    case socket.assigns.order["currentQuote"] do
      %{"id" => quote_id} ->
        {:ok, %{revision: socket.assigns.order["revision"], quote_id: quote_id}}

      _ ->
        {:error, "Esta ação não está mais disponível para este pedido. Confira a situação atual."}
    end
  end

  defp command(socket, :quote) do
    with {:ok, cents} <- Money.parse_brl(socket.assigns.amount),
         [file] <-
           consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
             {:ok, %{name: entry.client_name, bytes: File.read!(path)}}
           end) do
      {:ok, %{amount_cents: cents, order_revision: socket.assigns.order["revision"], file: file}}
    else
      _ -> {:error, "Escolha o arquivo do orçamento e informe o valor de novo."}
    end
  end

  defp run(socket, action, input, pre) do
    socket = assign(socket, :confirm, nil)

    case Intent.outcome(execute(socket, action, input, pre)) do
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
        assign(socket, result: :not_found, pending: nil)

      {:refused, message, keep_key?} ->
        socket
        |> assign(pending: nil, key: if(keep_key?, do: pre.idempotency_key, else: Intent.new_key()))
        |> load()
        |> notice({:error, message})

      {:failed, message} ->
        socket |> assign(:pending, nil) |> notice({:error, message})
    end
  end

  defp execute(socket, :collect, input, pre),
    do: UseCases.CollectFiles.collect_files(Deps.fetch(socket), socket.assigns.id, input, pre)

  defp execute(socket, :print, input, pre),
    do: UseCases.MarkPrinted.mark_printed(Deps.fetch(socket), socket.assigns.id, input, pre)

  defp execute(socket, :quote, input, pre),
    do: UseCases.SubmitQuote.submit_quote(Deps.fetch(socket), socket.assigns.id, input, pre)

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

  # --- view ---

  @impl true
  def render(assigns) do
    ~H"""
    <.shell nav={%{csrf: @csrf, current: :orders}}>
      <p class="crumb"><.link navigate="/orders">Voltar para Pedidos</.link></p>

      <%= case @result do %>
        <% :not_found -> %>
          <.message
            title="Não encontrado"
            text="Este endereço não existe ou o pedido não está disponível para a gráfica."
            link={{"/orders", "Ir para Pedidos"}}
          />
        <% :unavailable -> %>
          <.unavailable />
        <% :ok -> %>
          {ticket(assigns)}
      <% end %>
    </.shell>
    """
  end

  defp unavailable(assigns) do
    ~H"""
    <section class="message" role="alert">
      <h1>Sem resposta do sistema do Incluir</h1>
      <p>Não foi possível consultar o pedido agora.</p>
      <div class="actions">
        <button type="button" class="button button--primary" phx-click="refresh">
          Consultar novamente
        </button>
      </div>
    </section>
    """
  end

  defp ticket(assigns) do
    ~H"""
    <article class="ticket" aria-labelledby="ticket-ref">
      <header class="ticket__head">
        <h1 id="ticket-ref" class="ticket__ref">{@order["reference"]}</h1>
        <p class="ticket__title">{@order["title"]}</p>
        <dl class="facts">
          <div>
            <dt>Situação</dt>
            <dd>
              <span class={"status status--#{@order["status"]}"}>{status_label(@order["status"])}</span>
            </dd>
          </div>
          <div>
            <dt>Revisão</dt><dd>{@order["revision"]}</dd>
          </div>
          <div :if={!@order["generalInstructions"]}>
            <dt>Cópias no total</dt><dd>{Order.total_copies(@order)}</dd>
          </div>
          <div>
            <dt>Criado em</dt><dd>{local_time(@order["createdAt"])}</dd>
          </div>
          <div :if={@order["collectedAt"]}>
            <dt>Retirado em</dt><dd>{local_time(@order["collectedAt"])}</dd>
          </div>
          <div :if={@order["printedAt"]}>
            <dt>Impresso em</dt><dd>{local_time(@order["printedAt"])}</dd>
          </div>
        </dl>
      </header>

      <ol :if={@order["status"] != "cancelled"} class="track" aria-label="Etapas do pedido">
        <li
          :for={{label, state} <- steps(@order)}
          class={"track__step track__step--#{state}"}
          aria-current={state == :current && "step"}
        >
          {label}
        </li>
      </ol>

      <%= if @notice == :unavailable do %>
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
      <% else %>
        <.notice notice={@notice} />
      <% end %>

      <section
        :if={@order["generalInstructions"]}
        id="general-instructions"
        aria-labelledby="general-title"
      >
        <h2 id="general-title">Instruções gerais</h2>
        <p>Instruções do pedido inteiro, sem vínculo individual com os arquivos.</p>
        <pre class="general-instructions__text">{@order["generalInstructions"]["text"]}</pre>
        <ul>
          <li :for={file <- @order["generalInstructions"]["files"]}>
            <span>{file["name"]}</span>
            <a href={"/api/print/v1/orders/#{@order["id"]}/files/#{file["id"]}"}>Baixar arquivo</a>
          </li>
        </ul>
      </section>
      <section :if={!@order["generalInstructions"]} class="jobs" aria-labelledby="jobs-title">
        <h2 id="jobs-title">Arquivos e instruções da revisão {@order["revision"]}</h2>
        <ul class="jobs__list">
          <li :for={job <- @order["jobs"]} class="job">
            <div class="job__head">
              <h3 class="job__title">{job["title"]}</h3>
              <p class="job__copies">
                <strong>{job["copies"]}</strong> {if job["copies"] == 1, do: "cópia", else: "cópias"}
              </p>
            </div>
            <p class="job__instructions">{job["instructions"]}</p>
            <p class="job__file">
              <span class="job__filename">{job["file"]["name"]}</span>
              <span class="job__size">{file_size(job["file"]["bytes"])}</span>
              <a
                class="button button--small"
                href={"/api/print/v1/orders/#{@order["id"]}/files/#{job["file"]["id"]}"}
                download
              >
                Baixar arquivo
              </a>
            </p>
          </li>
        </ul>
      </section>

      <section class="panel" aria-labelledby="panel-title">
        {next_action(assigns)}
      </section>
    </article>
    """
  end

  defp next_action(%{action: :collect} = assigns) do
    ~H"""
    <h2 id="panel-title">Retirada dos arquivos</h2>
    <p>
      Baixe e confira todos os arquivos acima. Depois confirme a retirada — baixar sozinho não confirma nada.
    </p>
    <form id="collect-form" phx-submit="collect" class="stack">
      <label class="check">
        <input type="checkbox" name="conferi" value="on" required />
        Conferi todos os arquivos desta revisão
      </label>
      <div :if={@confirm != :collect} class="actions">
        <button type="submit" class="button button--primary">Arquivos retirados</button>
      </div>
    </form>
    <.confirm
      :if={@confirm == :collect}
      id="confirm-collect"
      action="collect"
      title="Confirmar retirada"
      ok="Confirmar retirada"
    >
      Você confirma que retirou os {length(@order["generalInstructions"]["files"] || @order["jobs"])} arquivos da revisão {@order[
        "revision"
      ]} de {@order[
        "reference"
      ]}?
    </.confirm>
    """
  end

  defp next_action(%{action: action} = assigns) when action in [:quote, :requote] do
    ~H"""
    <%= if @action == :requote do %>
      <h2 id="panel-title">Orçamento rejeitado</h2>
      <p class="notice notice--error">
        <strong>Motivo do Financeiro:</strong> {@order["currentQuote"]["rejectionReason"] ||
          "não informado"}
      </p>
      <p>Envie um novo orçamento. O anterior fica guardado no histórico.</p>
    <% else %>
      <h2 id="panel-title">Orçamento</h2>
      <p>Informe o valor e anexe o orçamento (PDF, JPEG, PNG ou WebP, até 5 MB).</p>
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
        <button type="submit" class="button button--primary">
          {if @action == :requote, do: "Enviar novo orçamento", else: "Enviar orçamento"}
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
      para {@order["reference"]}, revisão {@order["revision"]}?
    </.confirm>
    """
  end

  defp next_action(%{action: :await_decision} = assigns) do
    ~H"""
    <h2 id="panel-title">Aguardando aprovação do Financeiro</h2>
    <p>
      Orçamento de <strong>{money(@order["currentQuote"]["amountCents"])}</strong>
      enviado em {local_time(@order["currentQuote"]["submittedAt"])}. Você será liberado para imprimir quando o Financeiro aprovar.
    </p>
    <p>
      <a
        class="button button--small"
        href={"/api/print/v1/orders/#{@order["id"]}/quotes/#{@order["currentQuote"]["id"]}/file"}
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
      Valor aprovado: <strong>{money(@order["currentQuote"]["amountCents"])}</strong>. Imprima e depois confirme aqui.
    </p>
    <div :if={@confirm != :print} class="actions">
      <button type="button" class="button button--primary" phx-click="print">
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
      Confirma que {@order["reference"]} (revisão {@order["revision"]}) foi impresso? Esta confirmação não pode ser desfeita pelo portal.
    </.confirm>
    """
  end

  defp next_action(%{action: :none} = assigns) do
    ~H"""
    <%= if @order["status"] == "cancelled" do %>
      <h2 id="panel-title">Pedido cancelado</h2>
      <p><strong>Motivo:</strong> {@order["cancellationReason"] || "não informado"}</p>
      <p>Se você já retirou os arquivos, descarte as cópias deste pedido.</p>
    <% else %>
      <h2 id="panel-title">Impresso</h2>
      <p>
        Impressão confirmada em {local_time(@order["printedAt"])}. Valor aprovado: <strong>{money(@order["approvedAmountCents"])}</strong>. O pedido entra na nota fiscal do mês.
      </p>
    <% end %>
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
