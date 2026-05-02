defmodule SymphonyElixir.ManagerReleaseGuard do
  @moduledoc """
  Checks whether a shaped issue is safe for manager release into `Todo`.

  This is intentionally a small text guard. It gives manager agents a local
  dry-run check for dependency declarations before they move a parked Backlog
  issue into a Symphony-polled state.
  """

  @type dependency :: %{line: pos_integer(), text: String.t()}

  @dependency_heading ~r/^\#{2,6}\s+Dependencies\b/i
  @heading ~r/^\#{1,6}\s+/
  @explicit_dependency ~r/\bdepends\s+on\s*:?/i
  @none ~r/^\s*[-*]?\s*(none|n\/a|not applicable)\.?\s*$/i
  @checked ~r/^\s*[-*]\s*\[x\]/i
  @resolved ~r/\b(resolved by|status:\s*(resolved|done)|unblocked by)\b/i
  @completed_reference ~r/\b(landed|merged|deployed)\s+in\s+(`?[a-f0-9]{7,40}`?|PR\s*#\d+|#\d+)\b/i

  @spec check(String.t()) :: {:ok, [dependency()]} | {:error, [dependency()]}
  def check(text) when is_binary(text) do
    unresolved = unresolved_dependencies(text)

    if unresolved == [] do
      {:ok, []}
    else
      {:error, unresolved}
    end
  end

  @spec unresolved_dependencies(String.t()) :: [dependency()]
  def unresolved_dependencies(text) when is_binary(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, line_number}, {in_dependencies?, unresolved} ->
      next_in_dependencies? = dependencies_section?(line, in_dependencies?)

      unresolved =
        if dependency_declaration?(line, next_in_dependencies?) and not resolved_dependency?(line) do
          [%{line: line_number, text: String.trim(line)} | unresolved]
        else
          unresolved
        end

      {next_in_dependencies?, unresolved}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp dependencies_section?(line, in_dependencies?) when is_binary(line) do
    cond do
      Regex.match?(@dependency_heading, line) -> true
      Regex.match?(@heading, line) -> false
      true -> in_dependencies?
    end
  end

  defp dependency_declaration?(line, in_dependencies?) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> false
      Regex.match?(@none, trimmed) -> false
      Regex.match?(@explicit_dependency, trimmed) -> true
      in_dependencies? and bullet_or_checkbox?(trimmed) -> true
      true -> false
    end
  end

  defp bullet_or_checkbox?(line), do: String.starts_with?(line, ["-", "*"])

  defp resolved_dependency?(line) do
    Regex.match?(@checked, line) or Regex.match?(@resolved, line) or
      Regex.match?(@completed_reference, line)
  end
end
