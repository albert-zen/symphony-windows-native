defmodule SymphonyElixir.Redactor do
  @moduledoc """
  Redacts credential-like values before runtime event payloads are stored or rendered.
  """

  @redacted "[REDACTED]"
  @sensitive_name_pattern [
    "api[_-]?key",
    "authorization",
    "bearer",
    "cookie",
    "credential",
    "password",
    "private[_-]?key",
    "secret",
    "token"
  ]

  @sensitive_key_pattern ~r/(api[_-]?key|authorization|bearer|cookie|credential|password|private[_-]?key|secret|^token$|[_-]token$|token[_-]|access[_-]?token|refresh[_-]?token|session[_-]?token|id[_-]?token)/i
  @credential_url_pattern ~r{([a-z][a-z0-9+.-]*://)([^/\s:@]+):([^@\s/]+)@}i
  @sensitive_query_names [
    "access[_-]?token",
    "api[_-]?key",
    "client[_-]?secret",
    "code",
    "id[_-]?token",
    "key",
    "password",
    "refresh[_-]?token",
    "secret",
    "session[_-]?token",
    "token"
  ]
  @sensitive_query_pattern Regex.compile!(
                             "([?&](?:#{Enum.join(@sensitive_query_names, "|")})=).*?(?=(&|#|[[:space:]]|$))",
                             "i"
                           )
  @authorization_pattern ~r/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+/i
  @assignment_pattern ~r/\b([A-Za-z0-9_]*(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|PRIVATE[_-]?KEY|CREDENTIAL)[A-Za-z0-9_]*)=([^\s&]+)/i
  @json_secret_field_pattern Regex.compile!(
                               ~s/("[^"]*(?:#{Enum.join(@sensitive_name_pattern, "|")})[^"]*"\\s*:\\s*")[^"]*(")/,
                               "i"
                             )
  @standalone_secret_pattern Regex.compile!(
                               "\\b(?:" <>
                                 "sk-[A-Za-z0-9_-]{8,}|" <>
                                 "github_pat_[A-Za-z0-9_]{20,}|" <>
                                 "gh[opsu]_[A-Za-z0-9_]{20,}|" <>
                                 "glpat-[A-Za-z0-9_-]{20,}|" <>
                                 "xox[baprs]-[A-Za-z0-9-]{10,}|" <>
                                 "AKIA[0-9A-Z]{16}" <>
                                 ")\\b"
                             )

  @spec redact(term()) :: term()
  def redact(value), do: redact_value(value, nil)

  defp redact_value(value, key) when is_struct(value) do
    if sensitive_key?(key), do: @redacted, else: value
  end

  defp redact_value(value, key) when is_map(value) do
    if sensitive_key?(key) do
      @redacted
    else
      Map.new(value, fn {child_key, child_value} ->
        {child_key, redact_value(child_value, child_key)}
      end)
    end
  end

  defp redact_value(value, key) when is_list(value) do
    if sensitive_key?(key) do
      @redacted
    else
      Enum.map(value, &redact_value(&1, nil))
    end
  end

  defp redact_value(value, key) when is_binary(value) do
    if sensitive_key?(key), do: @redacted, else: redact_string(value)
  end

  defp redact_value(value, _key), do: value

  defp sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))
  defp sensitive_key?(key) when is_binary(key), do: Regex.match?(@sensitive_key_pattern, key)
  defp sensitive_key?(_key), do: false

  defp redact_string(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        decoded
        |> redact_value(nil)
        |> Jason.encode!()

      _ ->
        value
        |> then(&Regex.replace(@json_secret_field_pattern, &1, "\\1[REDACTED]\\2"))
        |> then(&Regex.replace(@credential_url_pattern, &1, "\\1[REDACTED]:[REDACTED]@"))
        |> then(&Regex.replace(@sensitive_query_pattern, &1, "\\1[REDACTED]"))
        |> then(&Regex.replace(@authorization_pattern, &1, "\\1 [REDACTED]"))
        |> then(&Regex.replace(@assignment_pattern, &1, "\\1=[REDACTED]"))
        |> then(&Regex.replace(@standalone_secret_pattern, &1, @redacted))
    end
  end
end
