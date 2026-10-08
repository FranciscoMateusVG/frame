defmodule Frame.Config do
  @moduledoc """
  Runtime configuration of the portal, read once from the environment at
  boot (spec §5, §10). Fails closed: any missing or invalid required value
  stops the release from starting. Error messages name the variable and the
  rule — never the value.

  | Variable | Rule |
  |---|---|
  | `PRINT_PORTAL_PASSWORD` | required, ≥ 12 characters |
  | `INCLUIR_PRINT_SERVICE_TOKEN` | required, 32–512 token characters, ≠ password |
  | `INCLUIR_PRINT_API_ORIGIN` | required, `http(s)://host[:port]`, no path/query/userinfo |
  | `PRINT_PORTAL_ORIGIN` | required, `http(s)://host[:port]` — the exact browser Origin |
  | `PORT` | optional, default 4000 |
  | `PRINT_PORTAL_TRUSTED_PROXIES` | optional, comma-separated CIDRs whose `X-Forwarded-For` is trusted |
  | `PRINT_PORTAL_SESSION_IDLE_SECONDS` / `PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS` | optional, may only *shorten* 30 min / 8 h (isolated test environments) |
  | `PRINT_PORTAL_UPSTREAM_TIMEOUT_MS` | optional, 1000–60000, default 15000 |
  """

  alias Frame.Domain.Session

  @derive {Inspect, only: [:api_origin, :portal_origin, :port]}
  @enforce_keys [:password, :service_token, :api_origin, :portal_origin]
  defstruct [
    :password,
    :service_token,
    :api_origin,
    :portal_origin,
    port: 4000,
    trusted_proxies: [],
    session_policy: nil,
    upstream_timeout_ms: 15_000
  ]

  @type cidr :: {:inet.ip_address(), 0..128}

  @type t :: %__MODULE__{
          password: String.t(),
          service_token: String.t(),
          api_origin: String.t(),
          portal_origin: String.t(),
          port: 1..65_535,
          trusted_proxies: [cidr()],
          session_policy: Session.policy(),
          upstream_timeout_ms: pos_integer()
        }

  @doc "Reads and validates the configuration from an env map (e.g. `System.get_env/0`)."
  @spec from_env(%{String.t() => String.t()}) :: {:ok, t()} | {:error, [String.t()]}
  def from_env(env) do
    results = [
      password: required(env, "PRINT_PORTAL_PASSWORD", &password/1),
      service_token: required(env, "INCLUIR_PRINT_SERVICE_TOKEN", &token/1),
      api_origin: required(env, "INCLUIR_PRINT_API_ORIGIN", &origin/1),
      portal_origin: required(env, "PRINT_PORTAL_ORIGIN", &origin/1),
      port: optional(env, "PORT", 4000, &integer_in(&1, 1..65_535)),
      trusted_proxies: optional(env, "PRINT_PORTAL_TRUSTED_PROXIES", [], &cidrs/1),
      idle: optional(env, "PRINT_PORTAL_SESSION_IDLE_SECONDS", nil, &integer_in(&1, 1..1800)),
      absolute:
        optional(env, "PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS", nil, &integer_in(&1, 1..28_800)),
      upstream_timeout_ms:
        optional(env, "PRINT_PORTAL_UPSTREAM_TIMEOUT_MS", 15_000, &integer_in(&1, 1000..60_000))
    ]

    errors = for {_key, {:error, message}} <- results, do: message
    values = for {key, {:ok, value}} <- results, into: %{}, do: {key, value}

    errors =
      if errors == [] and values.password == values.service_token,
        do: ["INCLUIR_PRINT_SERVICE_TOKEN must differ from PRINT_PORTAL_PASSWORD"],
        else: errors

    if errors == [], do: {:ok, build(values)}, else: {:error, errors}
  end

  defp build(values) do
    overrides =
      [idle_seconds: values.idle, absolute_seconds: values.absolute]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    %__MODULE__{
      password: values.password,
      service_token: values.service_token,
      api_origin: values.api_origin,
      portal_origin: values.portal_origin,
      port: values.port,
      trusted_proxies: values.trusted_proxies,
      session_policy: Session.policy(overrides),
      upstream_timeout_ms: values.upstream_timeout_ms
    }
  end

  defp required(env, name, parse) do
    case Map.get(env, name) do
      value when is_binary(value) and value != "" -> tag(parse.(value), name)
      _ -> {:error, "#{name} is required"}
    end
  end

  defp optional(env, name, default, parse) do
    case Map.get(env, name) do
      value when is_binary(value) and value != "" -> tag(parse.(value), name)
      _ -> {:ok, default}
    end
  end

  defp tag({:ok, value}, _name), do: {:ok, value}
  defp tag({:error, rule}, name), do: {:error, "#{name} #{rule}"}

  defp password(value) do
    if String.valid?(value) and String.length(value) >= 12,
      do: {:ok, value},
      else: {:error, "must have at least 12 characters"}
  end

  defp token(value) do
    if Regex.match?(~r/^[A-Za-z0-9._~+\/=-]{32,512}$/, value),
      do: {:ok, value},
      else: {:error, "must be 32–512 token characters"}
  end

  @doc "Validates an origin (`scheme://host[:port]`) and returns it normalized."
  @spec origin(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def origin(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             uri.path in [nil, "", "/"] ->
        default_port = if scheme == "https", do: 443, else: 80
        port = if uri.port == default_port, do: "", else: ":#{uri.port}"
        {:ok, "#{scheme}://#{String.downcase(host)}#{port}"}

      _ ->
        {:error, "must be an http(s) origin without path, query or credentials"}
    end
  end

  defp integer_in(value, range) do
    case Integer.parse(value) do
      {n, ""} -> if n in range, do: {:ok, n}, else: {:error, "is out of range"}
      _ -> {:error, "must be an integer"}
    end
  end

  @doc "Parses a comma-separated CIDR list (`10.0.0.0/8, ::1/128`, bare IPs allowed)."
  @spec cidrs(String.t()) :: {:ok, [cidr()]} | {:error, String.t()}
  def cidrs(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case cidr(entry) do
        {:ok, c} -> {:cont, {:ok, [c | acc]}}
        :error -> {:halt, {:error, "has an invalid CIDR"}}
      end
    end)
    |> then(fn
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end)
  end

  defp cidr(entry) do
    {address, bits} =
      case String.split(entry, "/") do
        [address] -> {address, nil}
        [address, bits] -> {address, bits}
        _ -> {"", nil}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         max = if(tuple_size(ip) == 4, do: 32, else: 128),
         {:ok, prefix} <- prefix(bits, max) do
      {:ok, {ip, prefix}}
    else
      _ -> :error
    end
  end

  defp prefix(nil, max), do: {:ok, max}

  defp prefix(bits, max) do
    case Integer.parse(bits) do
      {n, ""} when n >= 0 and n <= max -> {:ok, n}
      _ -> :error
    end
  end
end
