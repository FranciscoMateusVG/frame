defmodule Frame.Errors.PortalError do
  @moduledoc """
  A portal-side failure with its contract code and HTTP status (spec §4.5).
  Upstream contract errors (404/409/412/…) are not wrapped in this — they are
  relayed as the upstream answered. Messages are fixed Portuguese text;
  nothing from the request is ever interpolated.
  """

  @definitions %{
    unauthenticated: {401, "UNAUTHENTICATED", "Sessão ausente ou expirada. Entre novamente."},
    invalid_credentials: {401, "INVALID_CREDENTIALS", "Senha incorreta."},
    csrf_failed: {403, "CSRF_FAILED", "Requisição recusada (origem ou token CSRF inválidos)."},
    invalid_request: {400, "INVALID_REQUEST", "Requisição inválida."},
    invalid_competence: {400, "INVALID_COMPETENCE", "Competência inválida. Use AAAA-MM."},
    not_found: {404, "NOT_FOUND", "Recurso não encontrado."},
    method_not_allowed: {405, "METHOD_NOT_ALLOWED", "Método não permitido."},
    precondition_required:
      {428, "PRECONDITION_REQUIRED", "Cabeçalhos If-Match e Idempotency-Key são obrigatórios."},
    file_too_large: {413, "FILE_TOO_LARGE", "Arquivo acima de 5 MB."},
    unsupported_media_type:
      {415, "UNSUPPORTED_MEDIA_TYPE", "Formato não aceito. Envie PDF, JPEG, PNG ou WebP."},
    rate_limited: {429, "RATE_LIMITED", "Muitas tentativas. Tente novamente mais tarde."},
    upstream_unavailable:
      {503, "UPSTREAM_UNAVAILABLE", "Serviço temporariamente indisponível. Tente novamente."},
    internal: {500, "INTERNAL", "Erro interno."}
  }

  defexception [:reason, :status, :code, :message, retry_after: nil]

  @type reason ::
          :unauthenticated
          | :invalid_credentials
          | :csrf_failed
          | :invalid_request
          | :invalid_competence
          | :not_found
          | :method_not_allowed
          | :precondition_required
          | :file_too_large
          | :unsupported_media_type
          | :rate_limited
          | :upstream_unavailable
          | :internal

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer(),
          code: String.t(),
          message: String.t(),
          retry_after: pos_integer() | nil
        }

  @impl true
  def exception(reason) when is_atom(reason), do: exception({reason, nil})

  def exception({reason, retry_after}) do
    {status, code, message} = Map.fetch!(@definitions, reason)

    %__MODULE__{
      reason: reason,
      status: status,
      code: code,
      message: message,
      retry_after: retry_after
    }
  end
end
