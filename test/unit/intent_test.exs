defmodule Frame.Unit.IntentTest do
  @moduledoc "What an upstream answer means for a page command."
  use ExUnit.Case, async: true

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Domain.Requests
  alias Frame.Errors.PortalError
  alias Frame.Web.Intent

  defp resp(status, body \\ %{}), do: {:ok, %Response{status: status, body: body}}
  defp code(c), do: %{"error" => %{"code" => c, "message" => "m"}}

  test "outcomes" do
    assert Intent.outcome(resp(201)) == :done
    assert Intent.outcome(resp(404)) == :not_found

    assert Intent.outcome(resp(412, code("VERSION_MISMATCH"))) ==
             {:refused, "Pedido atualizado; confira novamente.", false}

    assert {:refused, _, true} = Intent.outcome(resp(409, code("OPERATION_IN_PROGRESS")))

    assert Intent.outcome(resp(409, code("NOVO"))) ==
             {:refused, "Não foi possível concluir a operação.", false}

    assert Intent.outcome(resp(422)) == {:refused, "Não foi possível concluir a operação.", false}
    assert Intent.outcome({:error, PortalError.exception(:upstream_unavailable)}) == :unavailable

    assert {:failed, "Arquivo acima de 5 MB."} =
             Intent.outcome({:error, PortalError.exception(:file_too_large)})
  end

  test "keys are fresh v4 UUIDs" do
    a = Intent.new_key()
    assert {:ok, ^a} = Requests.uuid(a)
    refute a == Intent.new_key()
  end

  test "upload errors" do
    assert Intent.upload_error(:too_many_files) == "Envie um único arquivo."
    assert Intent.upload_error(:external_client_failure) =~ "Tente de novo"
  end
end
