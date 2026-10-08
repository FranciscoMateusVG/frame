defmodule Frame.Web.Intent do
  @moduledoc """
  A supplier command from a page (collect, quote, print, NF) and what its
  answer means for the page (spec §4.5, §7).

  Each intent gets an Idempotency-Key minted server side when the page
  offers the action; a repeat after "no answer" (503) reuses that key and
  the very same input and If-Match, so it can never become a second,
  different command. A definitive answer — success or a contract error —
  ends the intent and the next one gets a fresh key.
  """

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Errors.PortalError

  @type outcome ::
          :done
          | :not_found
          | :unavailable
          | {:refused, String.t(), keep_key :: boolean()}
          | {:failed, String.t()}

  @messages %{
    "VERSION_MISMATCH" => "Pedido atualizado; confira novamente.",
    "INVALID_STATE" =>
      "Esta ação não está mais disponível para este pedido. Confira a situação atual.",
    "IDEMPOTENCY_CONFLICT" =>
      "Esta confirmação já foi usada para outra operação. Confira o pedido.",
    "OPERATION_IN_PROGRESS" =>
      "A operação ainda está em andamento. Consulte novamente em instantes.",
    "FILE_TOO_LARGE" => "O arquivo passa de 5 MB.",
    "UNSUPPORTED_MEDIA_TYPE" => "Formato não aceito. Envie PDF, JPEG, PNG ou WebP.",
    "PRECONDITION_REQUIRED" => "Recarregue a página e tente novamente.",
    "RATE_LIMITED" => "Muitas operações seguidas. Aguarde um pouco e tente novamente.",
    "PERIOD_OPEN" =>
      "A competência ainda não terminou. A NF só pode ser enviada depois do fim do mês.",
    "EMPTY_CLOSE" => "Não há pedidos impressos nesta competência.",
    "INVALID_REQUEST" => "Dados inválidos. Confira os campos e tente novamente.",
    "INVALID_COMPETENCE" => "Competência inválida."
  }

  @doc "A fresh Idempotency-Key (UUID v4)."
  @spec new_key() :: String.t()
  def new_key do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
  end

  @doc "What a use-case answer means for the page."
  @spec outcome({:ok, Response.t()} | {:error, PortalError.t()}) :: outcome()
  def outcome({:ok, %Response{status: status}}) when status in 200..299, do: :done
  def outcome({:ok, %Response{status: 404}}), do: :not_found

  def outcome({:ok, %Response{body: %{"error" => %{"code" => code}}}}),
    do: {:refused, message(code), code == "OPERATION_IN_PROGRESS"}

  def outcome({:ok, %Response{}}), do: {:refused, message(nil), false}
  def outcome({:error, %PortalError{reason: :upstream_unavailable}}), do: :unavailable
  def outcome({:error, %PortalError{message: message}}), do: {:failed, message}

  @doc "The supplier-facing text of an upstream contract code."
  @spec message(String.t() | nil) :: String.t()
  def message(code), do: Map.get(@messages, code, "Não foi possível concluir a operação.")

  @doc "The text for an upload error of LiveView."
  @spec upload_error(atom()) :: String.t()
  def upload_error(:too_large), do: "O arquivo passa de 5 MB."
  def upload_error(:not_accepted), do: "Formato não aceito. Envie PDF, JPEG, PNG ou WebP."
  def upload_error(:too_many_files), do: "Envie um único arquivo."
  def upload_error(_other), do: "Não foi possível receber o arquivo. Tente de novo."
end
