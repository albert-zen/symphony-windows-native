defmodule SymphonyElixir.Codex.ValidationEvidence do
  @moduledoc false

  @test_plan_heading_regex ~r/^\#{1,6}\s+Test Plan\s*$/m
  @heading_regex ~r/^\#{1,6}\s+.+$/m
  @checked_checkbox_regex ~r/^\s*[-*]\s+\[[xX]\]\s+(.+)$/m
  @unchecked_checkbox_regex ~r/^\s*[-*]\s+\[ \]\s+(.+)$/m
  @heavy_check_regex ~r/(^|[^a-z0-9_-])(make(?:\.cmd)?\s+(-C\s+elixir\s+)?all|make-all)([^a-z0-9_-]|$)/i
  @ci_only_regex ~r/(?:(?:^\s*(?:ci|github actions?)\b\s*(?::|-|[a-z]+\b))|\bci[-\s]+only\b|\b(?:in|by|via|on|from)\s+(?:ci|github actions?)\b)/i
  @unsuccessful_result_regex ~r/\b(?:failed|failing|errored|timed\s+out|timeout|timedout|cancelled|canceled)\b/i
  @skip_words ~w(skip skipped not cannot can't unable unavailable pending later)
  @restated_skip_words ~w(all cannot can't check gate heavy local locally make not run skipped to unable unavailable validation)
  @inline_code_regex ~r/`([^`]+)`/
  @validation_command_regex ~r/^\s*(?:[A-Z_][A-Z0-9_]*=\S+\s+)*(?:(?:mix\s+(?:test|format|pr_body\.check|specs\.check|symphony\.preflight\.windows)\b)|(?:make(?:\.cmd)?(?:\s+-C\s+\S+)?\s+(?:all|test|windows-native-test|diff-check|validate-pr-description|[\w.-]*test[\w.-]*|[\w.-]*check[\w.-]*))|(?:git\s+diff\s+--check\b)|(?:(?:npm|pnpm|yarn)\s+(?:test|lint|format|check|typecheck|type-check)\b))/i

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
    |> require_heavy_skip_justification(section, unchecked_items, local_evidence_items)
  end

  defp require_local_validation_evidence(errors, []),
    do: errors ++ ["Test Plan must include at least one checked local validation command or targeted check."]

  defp require_local_validation_evidence(errors, _items), do: errors

  defp require_heavy_skip_justification(errors, section, unchecked_items, local_evidence_items) do
    heavy_checked? = Enum.any?(local_evidence_items, &heavy_check?/1)
    heavy_skip_items = heavy_skip_items(section, unchecked_items)

    cond do
      heavy_checked? ->
        errors

      not Enum.any?(heavy_skip_items, &heavy_skip_justified?/1) ->
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

    has_validation_command?(item) and
      not only_delegates_to_ci?(normalized) and
      not ci_only_evidence?(item) and
      not unsuccessful_result?(item) and
      not explicit_skip_evidence?(normalized)
  end

  defp has_validation_command?(item) do
    item
    |> validation_command_candidates()
    |> Enum.any?(&Regex.match?(@validation_command_regex, &1))
  end

  defp validation_command_candidates(item) do
    inline_commands =
      @inline_code_regex
      |> Regex.scan(item)
      |> Enum.map(fn [_, command] -> command end)

    [item | inline_commands]
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

  defp ci_only_evidence?(item), do: Regex.match?(@ci_only_regex, item)

  defp unsuccessful_result?(item), do: Regex.match?(@unsuccessful_result_regex, item)

  defp heavy_check?(text), do: Regex.match?(@heavy_check_regex, text)

  defp heavy_skip_justified?(item) do
    normalized = normalize(item)

    concrete_due_to_reason?(normalized) or concrete_inability_reason?(normalized)
  end

  defp concrete_due_to_reason?(normalized) do
    case Regex.run(~r/\b(?:because|due to)\b\s+(.+)$/, normalized) do
      [_, reason] -> concrete_reason?(reason)
      _ -> false
    end
  end

  defp concrete_inability_reason?(normalized) do
    case Regex.run(~r/\b(?:cannot|can't|unable|unavailable)\b\s+(.+)$/, normalized) do
      [_, reason] -> concrete_reason?(reason)
      _ -> false
    end
  end

  defp concrete_reason?(reason) do
    reason
    |> String.replace(@inline_code_regex, " ")
    |> String.split(~r/[^a-z0-9']+/, trim: true)
    |> Enum.any?(&(&1 not in @restated_skip_words))
  end

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

  defp explicit_skip_evidence?(normalized) do
    explicit_skip_phrase?(normalized) or
      skipped_without_count?(normalized)
  end

  defp explicit_skip_phrase?(normalized) do
    [
      "not run",
      "did not run",
      "was not run",
      "wasn't run",
      "cannot",
      "can't",
      "unable",
      "unavailable",
      "pending",
      "later"
    ]
    |> Enum.any?(&String.contains?(normalized, &1))
  end

  defp skipped_without_count?(normalized) do
    if skipped_result_count?(normalized) and successful_result_summary?(normalized) do
      false
    else
      skipped_word?(normalized)
    end
  end

  defp skipped_word?(normalized) do
    normalized
    |> String.split(~r/[^a-z0-9']+/, trim: true)
    |> Enum.any?(fn
      "skipped" -> true
      "skip" -> true
      _ -> false
    end)
  end

  defp skipped_result_count?(normalized) do
    tokens = String.split(normalized, ~r/[^a-z0-9']+/, trim: true)

    numeric_skipped_count?(tokens) or numeric_tests_skipped_count?(tokens)
  end

  defp numeric_skipped_count?(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn
      [count, "skipped"] -> integer_string?(count)
      [count, "skip"] -> integer_string?(count)
      _ -> false
    end)
  end

  defp numeric_tests_skipped_count?(tokens) do
    tokens
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.any?(fn
      [count, test_word, "skipped"] when test_word in ["test", "tests"] -> integer_string?(count)
      [count, test_word, "skip"] when test_word in ["test", "tests"] -> integer_string?(count)
      _ -> false
    end)
  end

  defp successful_result_summary?(normalized) do
    Regex.match?(~r/\b(?:passed|passing|succeeded|successful|successfully)\b/, normalized) or
      Regex.match?(~r/\b(?:0|zero|no)\s+failures?\b/, normalized)
  end

  defp integer_string?(value), do: Regex.match?(~r/^\d+$/, value)

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
