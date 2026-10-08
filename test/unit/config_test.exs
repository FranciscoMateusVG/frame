defmodule Frame.Unit.ConfigTest do
  use ExUnit.Case, async: true

  alias Frame.Config
  alias Frame.Domain.Session

  @valid %{
    "PRINT_PORTAL_PASSWORD" => "uma-senha-bem-longa",
    "INCLUIR_PRINT_SERVICE_TOKEN" => String.duplicate("T", 43),
    "INCLUIR_PRINT_API_ORIGIN" => "http://hono-app:3000",
    "PRINT_PORTAL_ORIGIN" => "https://Grafica.programaincluir.org:443/"
  }

  test "valid configuration, normalized origins, defaults" do
    assert {:ok, c} = Config.from_env(@valid)
    assert c.api_origin == "http://hono-app:3000"
    assert c.portal_origin == "https://grafica.programaincluir.org"
    assert {c.port, c.trusted_proxies, c.upstream_timeout_ms} == {4000, [], 15_000}
    assert c.session_policy == Session.default_policy()
  end

  test "secrets never appear in inspect" do
    {:ok, c} = Config.from_env(@valid)
    refute inspect(c) =~ "uma-senha"
    refute inspect(c) =~ "TTTT"
  end

  test "rejects an 11-character password" do
    assert {:error, ["PRINT_PORTAL_PASSWORD must have at least 12 characters"]} =
             Config.from_env(Map.put(@valid, "PRINT_PORTAL_PASSWORD", String.duplicate("p", 11)))
  end

  test "accepts a 12-character password" do
    assert {:ok, _config} =
             Config.from_env(Map.put(@valid, "PRINT_PORTAL_PASSWORD", String.duplicate("p", 12)))
  end

  test "fails closed, naming variables and rules but never values" do
    assert {:error, errors} = Config.from_env(%{})
    assert length(errors) == 4
    assert Enum.all?(errors, &(&1 =~ "is required"))

    bad = %{
      @valid
      | "PRINT_PORTAL_PASSWORD" => "curta",
        "INCLUIR_PRINT_SERVICE_TOKEN" => "has spaces and is short",
        "INCLUIR_PRINT_API_ORIGIN" => "http://user:pw@host/path",
        "PRINT_PORTAL_ORIGIN" => "ftp://x"
    }

    assert {:error, errors} = Config.from_env(bad)
    assert length(errors) == 4
    for value <- ["curta", "has spaces", "user:pw"], do: refute(Enum.join(errors) =~ value)
  end

  test "optional values are validated" do
    for {k, v} <- [
          {"PORT", "0"},
          {"PORT", "abc"},
          {"PRINT_PORTAL_TRUSTED_PROXIES", "10.0.0.0/33"},
          {"PRINT_PORTAL_TRUSTED_PROXIES", "nope"},
          {"PRINT_PORTAL_TRUSTED_PROXIES", "10.0.0.0/8/1"},
          {"PRINT_PORTAL_SESSION_IDLE_SECONDS", "3600"},
          {"PRINT_PORTAL_UPSTREAM_TIMEOUT_MS", "10"}
        ] do
      assert {:error, [message]} = Config.from_env(Map.put(@valid, k, v)), "#{k}=#{v}"
      assert message =~ k
    end

    env =
      Map.merge(@valid, %{
        "PORT" => "4100",
        "PRINT_PORTAL_TRUSTED_PROXIES" => "10.0.0.0/8, ::1, 172.16.0.1",
        "PRINT_PORTAL_SESSION_IDLE_SECONDS" => "5",
        "PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS" => "20",
        "PRINT_PORTAL_UPSTREAM_TIMEOUT_MS" => "2000"
      })

    assert {:ok, c} = Config.from_env(env)
    assert c.port == 4100

    assert c.trusted_proxies == [
             {{10, 0, 0, 0}, 8},
             {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
             {{172, 16, 0, 1}, 32}
           ]

    assert {c.session_policy.idle_seconds, c.session_policy.absolute_seconds} == {5, 20}
    assert c.upstream_timeout_ms == 2000
  end

  test "the token must differ from the password" do
    env = %{
      @valid
      | "INCLUIR_PRINT_SERVICE_TOKEN" => String.duplicate("p", 40),
        "PRINT_PORTAL_PASSWORD" => String.duplicate("p", 40)
    }

    assert {:error, ["INCLUIR_PRINT_SERVICE_TOKEN must differ from PRINT_PORTAL_PASSWORD"]} =
             Config.from_env(env)
  end
end
