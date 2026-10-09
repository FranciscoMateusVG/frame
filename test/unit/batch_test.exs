defmodule Frame.Unit.BatchTest do
  @moduledoc "What the batch screen offers, from the frozen v2 snapshots."
  use ExUnit.Case, async: true

  alias Frame.Domain.Batch
  alias Frame.Test.BatchFixture

  test "the next supplier action follows the batch status" do
    expected = %{
      "open" => :collect,
      "files_collected" => :quote,
      "quote_pending" => :await_decision,
      "quote_rejected" => :requote,
      "quote_approved" => :print,
      "printed" => :await_receipt,
      "received" => :none,
      "cancelled" => :none
    }

    for {status, action} <- expected do
      assert Batch.next_action(BatchFixture.batch(status)) == action, status
    end

    # An empty open batch is not collectable; an approved status needs an approved quote.
    assert Batch.next_action(%{BatchFixture.batch("open") | "items" => []}) == :none
    no_quote = %{BatchFixture.batch("quote_approved") | "currentQuote" => nil}
    assert Batch.next_action(no_quote) == :none
  end

  test "active: collected until printed" do
    for status <- ~w(files_collected quote_pending quote_rejected quote_approved printed),
        do: assert(Batch.active?(BatchFixture.batch(status)), status)

    for status <- ~w(open received cancelled),
        do: refute(Batch.active?(BatchFixture.batch(status)), status)
  end

  test "labels, ETag, counts and the per-file cards of a request" do
    batch = BatchFixture.rebatched()
    [mixed, plain] = batch["items"]

    assert Batch.status_label("files_collected") == "Arquivos retirados"
    assert Batch.status_label("weird") == "weird"
    assert Batch.etag(batch) == ~s("#{batch["id"]}:1")
    assert Batch.total_copies(batch) == 24 + 12 + 8
    assert Batch.file_count(batch) == 4

    assert [{:job, j1}, {:job, j2}, {:residual, residual}] = Batch.cards(mixed)

    assert {j1["title"], j2["title"]} ==
             {"2.2 - Turma 9h - Revisão Tucanos", "3.1 - Turma 10h - Atividade Araras"}

    assert residual["name"] == "Documento sem bloco.pdf"
    assert [{:job, _}] = Batch.cards(plain)
  end

  test "the progress track: Pronto → … → Impresso" do
    labels = Enum.map(Batch.steps(BatchFixture.batch("open")), &elem(&1, 0))

    assert labels == [
             "Pronto",
             "Arquivos retirados",
             "Orçamento enviado",
             "Orçamento aprovado",
             "Impresso"
           ]

    assert Enum.map(Batch.steps(BatchFixture.batch("quote_rejected")), &elem(&1, 1)) ==
             [:done, :done, :current, :todo, :todo]

    assert Enum.map(Batch.steps(BatchFixture.batch("printed")), &elem(&1, 1)) ==
             [:done, :done, :done, :done, :done]

    assert Enum.all?(Batch.steps(BatchFixture.batch("received")), &(elem(&1, 1) == :done))
    assert Enum.all?(Batch.steps(BatchFixture.batch("cancelled")), &(elem(&1, 1) == :todo))
  end
end
