defmodule Frame.Domain.Document do
  @moduledoc """
  Supplier documents (quote and monthly invoice) and download names.

  Spec §4.3: one PDF/JPEG/PNG/WebP piece, at most 5 MiB, type detected from
  the bytes — never from the extension or the declared Content-Type. The
  upstream re-detects and transcodes; the portal checks first so a wrong
  file fails fast with the same 413/415 codes, without a round trip.
  """

  @max_bytes 5 * 1024 * 1024
  # Body cap for a supplier upload (file + fields + multipart framing).
  @max_body_bytes @max_bytes + 512 * 1024

  @type mime :: String.t()

  @doc "Maximum bytes of one quote/invoice file (5 MiB)."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "Maximum bytes of a whole upload request body (5 MiB + 512 KiB)."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "Detects an accepted MIME type from the leading bytes."
  @spec detect_mime(binary()) :: {:ok, mime()} | :error
  def detect_mime(<<"%PDF-", _::binary>>), do: {:ok, "application/pdf"}
  def detect_mime(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  def detect_mime(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: {:ok, "image/png"}
  def detect_mime(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  def detect_mime(_bytes), do: :error

  @doc """
  Validates a supplier document: non-empty, within the size cap, accepted
  type by magic bytes.
  """
  @spec validate(binary()) ::
          {:ok, mime()} | {:error, :empty | :too_large | :unsupported_media_type}
  def validate(bytes) when is_binary(bytes) do
    cond do
      bytes == "" -> {:error, :empty}
      byte_size(bytes) > @max_bytes -> {:error, :too_large}
      true -> with :error <- detect_mime(bytes), do: {:error, :unsupported_media_type}
    end
  end

  @doc """
  A file name safe for display and `Content-Disposition`: last path segment,
  no control characters (CR/LF included), trimmed, at most 200 characters;
  `arquivo` when nothing usable remains. Mirrors the upstream's rule.
  """
  @spec sanitize_name(term()) :: String.t()
  def sanitize_name(name) when is_binary(name) do
    clean =
      if String.valid?(name) do
        name
        |> String.split(["/", "\\"])
        |> List.last()
        |> String.replace(~r/[\x{0000}-\x{001F}\x{007F}]/u, "")
        |> String.trim()
        |> String.slice(0, 200)
      else
        ""
      end

    if clean in ["", ".", ".."], do: "arquivo", else: clean
  end

  def sanitize_name(_name), do: "arquivo"

  @doc """
  `Content-Disposition: attachment` with an ASCII fallback and an RFC 5987
  `filename*` for the UTF-8 name.
  """
  @spec content_disposition(String.t()) :: String.t()
  def content_disposition(name) do
    safe = sanitize_name(name)
    ascii = String.replace(safe, ~r/[^\x20-\x7E]|["\\;]/u, "_")

    ~s(attachment; filename="#{ascii}"; filename*=UTF-8''#{URI.encode(safe, &URI.char_unreserved?/1)})
  end
end
