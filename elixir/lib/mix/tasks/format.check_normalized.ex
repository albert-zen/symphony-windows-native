defmodule Mix.Tasks.Format.CheckNormalized do
  @moduledoc """
  Checks Elixir formatter output while ignoring CRLF/LF-only differences.
  """

  use Mix.Task

  alias Mix.Tasks.Format

  @shortdoc "Checks formatter output after newline normalization"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    root = File.cwd!()
    files = files_to_check(args, root)
    failures = Enum.filter(files, &format_changed?/1)

    if failures == [] do
      Mix.shell().info("format.check_normalized: all formatter inputs are formatted")
      :ok
    else
      Enum.each(failures, &Mix.shell().error("format.check_normalized: #{&1} is not formatted"))
      Mix.raise("format.check_normalized failed with #{length(failures)} unformatted file(s)")
    end
  end

  defp files_to_check([], root) do
    root
    |> formatter_inputs()
    |> Enum.flat_map(&Path.wildcard(&1, match_dot: true))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp files_to_check(args, _root) do
    args
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp formatter_inputs(root) do
    formatter_path = Path.join(root, ".formatter.exs")

    if File.exists?(formatter_path) do
      {config, _binding} = Code.eval_file(formatter_path)

      config
      |> Keyword.get(:inputs, [])
      |> Enum.map(&Path.expand(&1, root))
    else
      []
    end
  end

  defp format_changed?(file) do
    {formatter, _opts} = Format.formatter_for_file(file)
    source = File.read!(file)
    formatted = formatter.(source) |> IO.iodata_to_binary()

    normalize_newlines(source) != normalize_newlines(formatted)
  end

  defp normalize_newlines(value) when is_binary(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end
end
