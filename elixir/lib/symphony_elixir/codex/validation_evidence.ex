defmodule SymphonyElixir.Codex.ValidationEvidence do
  @moduledoc false

  @test_plan_heading_regex ~r/^\#{1,6}\s+Test Plan\s*$/m
  @heading_regex ~r/^\#{1,6}\s+.+$/m
  @checked_checkbox_regex ~r/^\s*[-*]\s+\[[xX]\]\s+(.+)$/m
  @unchecked_checkbox_regex ~r/^\s*[-*]\s+\[ \]\s+(.+)$/m
  @heavy_check_regex ~r/(^|[^a-z0-9_-])(make\s+(-C\s+elixir\s+)?all|make-all)([^a-z0-9_-]|$)/i
  @skip_words ~w(skip skipped not cannot can't unable unavailable pending later)
  @why_regex ~r/\b(because|due to|cannot|can't|unable|unavailable|not run|skipped|skip)\b/i
  @command_regex ~r/(`[^`]+`|\bmix\s+\S+|\bmake(\.cmd)?\s+\S+|\bmake\s+(-C\s+\S+\s+)?\S+|\bgh\s+\S+|\bnpm\s+\S+|\bpnpm\s+\S+|\byarn\s+\S+)/i

  @spec lint_pr_body(String.t()) :: [String.t()]
  def lint_pr_body(body) when is_binary(body) do
    case test_plan_section(body) do
      nil -> ["PR body must include a Test Plan section with local validation evidence."]
      section -> lint_test_plan(section)
    end
  end

  defp lint_test_plan(section) do
    checked_items = checked_items(section)
    unchecked_items = unchecked_items(section)
    local_evidence_items = Enum.filter(checked_items, &local_validation_evidence?/1)

    []
    |> require_local_validation_evidence(local_evidence_items)
    |> require_heavy_skip_justification(section, checked_items, unchecked_items, local_evidence_items)
  end

  defp require_local_validation_evidence(errors, []),
    do: errors ++ ["Test Plan must include at least one checked local validation command or targeted check."]

  defp require_local_validation_evidence(errors, _items), do: errors

  defp require_heavy_skip_justification(errors, section, checked_items, unchecked_items, local_evidence_items) do
    heavy_checked? = Enum.any?(checked_items, &heavy_check?/1)
    heavy_skip_items = heavy_skip_items(section, unchecked_items)
    heavy_skipped? = heavy_skip_items != []

    cond do
      heavy_checked? or not heavy_skipped? ->
        errors

      not Enum.any?(heavy_skip_items, &Regex.match?(@why_regex, &1)) ->
        errors ++ ["Test Plan must explain why the heavy local validation check was not run."]

      no_narrower_local_evidence?(local_evidence_items) ->
        errors ++ ["Test Plan must name narrower local validation when the heavy check is skipped."]

      true ->
        errors
    end
  end

  defp no_narrower_local_evidence?(items), do: not Enum.any?(items, &(not heavy_check?(&1)))

  defp local_validation_evidence?(item) do
    normalized = normalize(item)

    Regex.match?(@command_regex, item) and
      not only_delegates_to_ci?(normalized) and
      not skip_item?(normalized)
  end

  defp heavy_skip_items(section, unchecked_items) do
    unchecked_heavy_items = Enum.filter(unchecked_items, &heavy_check?/1)

    prose_skip_items =
      section
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(fn line -> heavy_check?(line) and skip_item?(normalize(line)) end)

    Enum.uniq(unchecked_heavy_items ++ prose_skip_items)
  end

  defp heavy_check?(text), do: Regex.match?(@heavy_check_regex, text)

  defp checked_items(section), do: checkbox_items(section, @checked_checkbox_regex)

  defp unchecked_items(section), do: checkbox_items(section, @unchecked_checkbox_regex)

  defp checkbox_items(section, regex) do
    regex
    |> Regex.scan(section)
    |> Enum.map(fn [_, item] -> String.trim(item) end)
  end

  defp skip_item?(normalized) do
    Enum.any?(@skip_words, &String.contains?(normalized, &1))
  end

  defp only_delegates_to_ci?(normalized) do
    String.contains?(normalized, "ci") and
      not Regex.match?(~r/\b(mix|make|npm|pnpm|yarn|gh|test|format|check)\b/, normalized)
  end

  defp test_plan_section(body) do
    with {heading_start, heading_length} <- first_match(@test_plan_heading_regex, body) do
      content_start = heading_start + heading_length
      content = binary_part(body, content_start, byte_size(body) - content_start)

      case first_match(@heading_regex, content) do
        nil -> content
        {next_heading_start, _next_heading_length} -> binary_part(content, 0, next_heading_start)
      end
    end
  end

  defp first_match(regex, body) do
    case Regex.run(regex, body, return: :index) do
      [{first, length} | _] -> {first, length}
      nil -> nil
    end
  end

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end
end
