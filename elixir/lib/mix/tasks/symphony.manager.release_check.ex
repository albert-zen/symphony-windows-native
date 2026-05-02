defmodule Mix.Tasks.Symphony.Manager.ReleaseCheck do
  @moduledoc """
  Checks whether a manager-shaped issue can be released into `Todo`.

      mix symphony.manager.release_check --file issue.md
  """

  use Mix.Task

  alias SymphonyElixir.ManagerReleaseGuard

  @shortdoc "Checks dependency declarations before manager Todo release"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [file: :string, help: :boolean])

    cond do
      opts[:help] ->
        Mix.shell().info("mix symphony.manager.release_check --file /path/to/issue.md")

      invalid != [] ->
        Mix.raise("Invalid option: #{inspect(invalid)}")

      is_nil(opts[:file]) ->
        Mix.raise("Missing required option --file")

      true ->
        opts[:file]
        |> read_file!()
        |> report()
    end
  end

  defp read_file!(path) do
    case File.read(path) do
      {:ok, body} -> body
      {:error, reason} -> Mix.raise("Unable to read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp report(body) do
    case ManagerReleaseGuard.check(body) do
      {:ok, _dependencies} ->
        Mix.shell().info("Manager release check OK: no unresolved dependencies found.")

      {:error, dependencies} ->
        Enum.each(dependencies, fn dependency ->
          Mix.shell().error("Unresolved dependency on line #{dependency.line}: #{dependency.text}")
        end)

        Mix.raise("Manager release check failed: unresolved dependencies must be resolved before Todo release")
    end
  end
end
