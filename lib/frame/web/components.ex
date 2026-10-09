defmodule Frame.Web.Components do
  @moduledoc """
  Function components and formatting helpers shared by the pages: the page
  shell (header + navigation + Sair), notices, and money / São Paulo time /
  label helpers. Every value is rendered through HEEx (escaped).
  """

  use Phoenix.Component

  alias Frame.Domain.Batch
  alias Frame.Domain.Close
  alias Frame.Domain.Competence
  alias Frame.Domain.Money

  @doc """
  The page shell. `nav` is `nil` (signed out) or `%{csrf: token, current:
  :batch | :history | :invoices | nil}`; Sair is a plain form POST to `/logout` (it
  drops a cookie, so it is not a socket event).
  """
  attr :nav, :map, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <header class="top">
      <div class="top__inner">
        <a class="brand" href="/">
          <span class="brand__mark" aria-hidden="true"></span>Gráfica
          <span class="brand__sub">Programa Incluir</span>
        </a>
        <nav :if={@nav} class="nav" aria-label="Principal">
          <.link navigate="/" aria-current={@nav.current == :batch && "page"}>Lote atual</.link>
          <.link navigate="/lotes" aria-current={@nav.current == :history && "page"}>
            Lotes anteriores
          </.link>
          <.link navigate="/invoices" aria-current={@nav.current == :invoices && "page"}>
            Notas fiscais
          </.link>
          <form method="post" action="/logout" class="nav__logout">
            <input type="hidden" name="_csrf" value={@nav.csrf} />
            <button type="submit" class="link-button">Sair</button>
          </form>
        </nav>
      </div>
    </header>
    <main class="page">
      {render_slot(@inner_block)}
    </main>
    """
  end

  @doc "A notice: `{:ok, text}`, `{:error, text}`, `{:wait, text}` or `nil`."
  attr :notice, :any, default: nil

  def notice(assigns) do
    ~H"""
    <%= case @notice do %>
      <% {:ok, text} -> %>
        <p class="notice notice--ok" role="status">{text}</p>
      <% {:error, text} -> %>
        <p class="notice notice--error" role="alert">{text}</p>
      <% {:wait, text} -> %>
        <p class="notice notice--wait" role="status">{text}</p>
      <% nil -> %>
    <% end %>
    """
  end

  @doc "A message page body (404, 403, 405)."
  attr :title, :string, required: true
  attr :text, :string, required: true
  attr :link, :any, required: true

  def message(assigns) do
    ~H"""
    <section class="message">
      <h1>{@title}</h1>
      <p>{@text}</p>
      <p><a class="button" href={elem(@link, 0)}>{elem(@link, 1)}</a></p>
    </section>
    """
  end

  # --- formatting helpers ---

  @doc "Cents as BRL (`R$ 1.234,56`), or `—`."
  def money(nil), do: "—"
  def money(cents), do: Money.format_brl(cents)

  @doc false
  def status_label(status), do: Batch.status_label(status)

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
      {:ok, dt, _} -> dt |> DateTime.add(-3 * 3600, :second) |> Calendar.strftime("%d/%m/%Y %H:%M")
      _ -> "—"
    end
  end

  @doc false
  def local_date(%Date{} = d), do: Calendar.strftime(d, "%d/%m/%Y")

  @doc "Bytes as `812 B`, `12,4 KB`, `1,2 MB`."
  def file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  def file_size(bytes) when bytes < 1024 * 1024, do: comma("#{Float.round(bytes / 1024, 1)} KB")
  def file_size(bytes), do: comma("#{Float.round(bytes / (1024 * 1024), 1)} MB")

  defp comma(text), do: String.replace(text, ".", ",")

  @doc false
  def opens_on(%Competence{} = c), do: local_date(Competence.opens_on(c))
end
