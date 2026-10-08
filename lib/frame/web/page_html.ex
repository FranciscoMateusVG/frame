defmodule Frame.Web.PageHTML do
  @moduledoc """
  The controller-rendered HTML pages: login, and the message pages (404,
  403, 405). Pages go through the root layout; the navigation shows only
  with a live session.
  """

  use Frame.Web, :html

  @messages %{
    not_found:
      {"Não encontrado", "Este endereço não existe ou o pedido não está disponível para a gráfica.",
       {"/orders", "Ir para Pedidos"}},
    forbidden:
      {"Requisição recusada",
       "A página expirou ou veio de outro endereço. Volte, recarregue a página e tente de novo.",
       {"/orders", "Recarregar Pedidos"}}
  }

  @doc "The login page (`error`: `nil`, `:invalid_credentials` or `:rate_limited`)."
  def login(conn, status, csrf, error) do
    render(conn, status, "Entrar", &login_body/1, %{csrf: csrf, error: error})
  end

  @doc "404 page."
  def not_found(conn), do: message(conn, 404, :not_found)

  @doc "403 page (Origin/CSRF refused)."
  def forbidden(conn), do: message(conn, 403, :forbidden)

  @doc "A message page with `status`."
  def message(conn, status, kind) do
    {title, text, link} = Map.fetch!(@messages, kind)

    render(conn, status, title, &message_body/1, %{
      title: title,
      text: text,
      link: link,
      nav: nav(conn)
    })
  end

  defp nav(%Plug.Conn{assigns: %{portal_session: %{csrf_token: csrf}}}),
    do: %{csrf: csrf, current: nil}

  defp nav(_conn), do: nil

  defp render(conn, status, title, body, assigns) do
    assigns = Map.put(assigns, :inner, body)

    conn
    |> Phoenix.Controller.put_format("html")
    |> Phoenix.Controller.put_root_layout(html: {Frame.Web.Layouts, :root})
    |> Phoenix.Controller.put_view(html: __MODULE__)
    |> Plug.Conn.assign(:page_title, title)
    |> Plug.Conn.put_status(status)
    |> Phoenix.Controller.render(:page, assigns)
  end

  @doc false
  def page(assigns) do
    ~H"""
    <.shell nav={assigns[:nav]}>
      {@inner.(assigns)}
    </.shell>
    """
  end

  defp login_body(assigns) do
    ~H"""
    <section class="login">
      <h1>Entrar</h1>
      <p class="lede">Portal de pedidos de impressão do Programa Incluir.</p>
      <p :if={@error} class="notice notice--error" role="alert">
        {if @error == :rate_limited,
          do: "Muitas tentativas. Aguarde alguns minutos e tente de novo.",
          else: "Senha incorreta."}
      </p>
      <form method="post" action="/login" class="stack">
        <input type="hidden" name="_csrf" value={@csrf} />
        <label class="field">
          <span class="field__label">Senha</span>
          <input type="password" name="password" autocomplete="current-password" required autofocus />
        </label>
        <button type="submit" class="button button--primary">Entrar</button>
      </form>
    </section>
    """
  end

  defp message_body(assigns) do
    ~H"""
    <.message title={@title} text={@text} link={@link} />
    """
  end
end
