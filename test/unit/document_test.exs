defmodule Frame.Unit.DocumentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Frame.Domain.Document

  test "detects types by magic bytes, not names" do
    assert Document.detect_mime("%PDF-1.7 ...") == {:ok, "application/pdf"}
    assert Document.detect_mime(<<0xFF, 0xD8, 0xFF, 0xE0>>) == {:ok, "image/jpeg"}
    assert Document.detect_mime(<<0x89, "PNG\r\n", 0x1A, "\n", 0>>) == {:ok, "image/png"}
    assert Document.detect_mime("RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8") == {:ok, "image/webp"}
    assert Document.detect_mime("<html><script>") == :error
    assert Document.detect_mime("PK\x03\x04zip") == :error
  end

  test "validate/1 enforces non-empty, 5 MiB and type" do
    assert Document.validate("") == {:error, :empty}

    assert Document.validate("%PDF-" <> :binary.copy("a", Document.max_bytes())) ==
             {:error, :too_large}

    assert Document.validate("<svg/>") == {:error, :unsupported_media_type}
    assert Document.validate("%PDF-1.4") == {:ok, "application/pdf"}
    assert Document.max_body_bytes() == 5 * 1024 * 1024 + 512 * 1024
  end

  test "sanitize_name/1 strips paths, controls and CRLF" do
    assert Document.sanitize_name("../../etc/passwd") == "passwd"
    assert Document.sanitize_name("C:\\Users\\x\\nota.pdf") == "nota.pdf"
    assert Document.sanitize_name("a\r\nSet-Cookie: x.pdf") == "aSet-Cookie: x.pdf"
    assert Document.sanitize_name("  ..  ") == "arquivo"
    assert Document.sanitize_name("") == "arquivo"
    assert Document.sanitize_name(<<0xFF, 0xFE>>) == "arquivo"
    assert Document.sanitize_name(nil) == "arquivo"
    assert String.length(Document.sanitize_name(String.duplicate("a", 300))) == 200
  end

  test "content_disposition/1 is header-safe with a UTF-8 filename*" do
    value = Document.content_disposition("física \"final\";.pdf")

    assert value ==
             ~s(attachment; filename="f_sica _final__.pdf"; filename*=UTF-8''f%C3%ADsica%20%22final%22%3B.pdf)
  end

  property "content_disposition/1 never contains control characters" do
    check all(name <- string(:printable)) do
      refute Document.content_disposition(name) =~ ~r/[\x00-\x1F\x7F]/
    end
  end
end
