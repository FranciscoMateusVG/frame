defmodule Frame.Web.Multipart do
  @moduledoc """
  Strict `multipart/form-data` reader for the supplier uploads (spec §4):

    * the whole body is capped (`max_body`) *while reading* — chunked
      uploads included — and a declared `Content-Length` above the cap is
      refused before reading anything;
    * exactly one part named `file` carrying a filename; every other part is
      a plain text field;
    * a repeated field name, a part without a name, a second file, a
      truncated body or a missing boundary are all `:invalid` (400) — the
      reader never guesses (Plug.Parsers would keep the last duplicate).

  Nothing is written to disk; the file is held in memory (≤ 5 MiB).
  """

  import Plug.Conn

  alias Plug.Conn.Utils

  @type file :: %{name: String.t(), bytes: binary()}
  @type result ::
          {:ok, Plug.Conn.t(), %{String.t() => String.t()}, file()}
          | {:error, Plug.Conn.t(), :invalid | :too_large}

  @max_field_bytes 4096
  @max_parts 8

  @doc "Reads the request body as a strict multipart form."
  @spec read(Plug.Conn.t(), pos_integer()) :: result()
  def read(conn, max_body) do
    with :ok <- declared_length_ok(conn, max_body),
         {:ok, boundary} <- boundary(conn) do
      opts = [length: 64_000, read_length: 64_000, read_timeout: 15_000, boundary: boundary]
      parts(conn, %{fields: %{}, file: nil, read: 0, count: 0}, max_body, opts)
    else
      {:error, reason} -> {:error, conn, reason}
    end
  end

  defp declared_length_ok(conn, max_body) do
    case get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {n, ""} when n > max_body -> {:error, :too_large}
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp boundary(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "multipart", "form-data", %{"boundary" => b}} when b != "" <-
           Utils.content_type(content_type) do
      {:ok, b}
    else
      _ -> {:error, :invalid}
    end
  end

  defp parts(conn, acc, max_body, opts) do
    case guarded(conn, fn -> read_part_headers(conn, opts) end) do
      {:ok, headers, conn} ->
        part(conn, headers, acc, max_body, opts)

      {:done, conn} ->
        case acc.file do
          nil -> {:error, conn, :invalid}
          file -> {:ok, conn, acc.fields, file}
        end

      {:error, conn, reason} ->
        {:error, conn, reason}
    end
  end

  defp part(conn, headers, acc, max_body, opts) do
    with {:ok, name, filename} <- disposition(headers),
         true <- acc.count < @max_parts,
         false <- Map.has_key?(acc.fields, name) or (name == "file" and acc.file != nil),
         {:ok, conn, body, read} <- body(conn, acc.read, max_body, opts, []) do
      acc = %{acc | read: read, count: acc.count + 1}
      store_part(conn, acc, {name, filename}, body, {max_body, opts})
    else
      {:error, conn, reason} -> {:error, conn, reason}
      _ -> {:error, conn, :invalid}
    end
  end

  defp store_part(conn, acc, {"file", filename}, body, {max_body, opts})
       when is_binary(filename),
       do: parts(conn, %{acc | file: %{name: filename, bytes: body}}, max_body, opts)

  defp store_part(conn, acc, {name, nil}, body, {max_body, opts})
       when name != "file" and byte_size(body) <= @max_field_bytes do
    if String.valid?(body),
      do: parts(conn, %{acc | fields: Map.put(acc.fields, name, body)}, max_body, opts),
      else: {:error, conn, :invalid}
  end

  defp store_part(conn, _acc, _name, _body, _limits), do: {:error, conn, :invalid}

  defp disposition(headers) do
    with {_, value} <- List.keyfind(headers, "content-disposition", 0),
         ["form-data" | params] <- String.split(value, ";", parts: 2),
         params = Utils.params(Enum.join(params)),
         name when is_binary(name) and name != "" <- params["name"] do
      {:ok, name, params["filename"]}
    else
      _ -> :error
    end
  end

  defp body(conn, read, max_body, opts, chunks) do
    case guarded(conn, fn -> read_part_body(conn, opts) end) do
      {status, data, conn} when status in [:ok, :more] ->
        read = read + byte_size(data)

        cond do
          read > max_body -> {:error, conn, :too_large}
          status == :ok -> {:ok, conn, IO.iodata_to_binary([chunks | data]), read}
          true -> body(conn, read, max_body, opts, [chunks | data])
        end

      {:done, conn} ->
        {:error, conn, :invalid}

      {:error, conn, reason} ->
        {:error, conn, reason}
    end
  end

  # Plug's multipart reader raises on malformed input (truncated body,
  # bad framing) and on socket read errors; all of those are a bad request.
  defp guarded(conn, read) do
    read.()
  rescue
    _ in [RuntimeError, Plug.BadRequestError, Bandit.HTTPError, Plug.TimeoutError] ->
      {:error, conn, :invalid}
  end
end
