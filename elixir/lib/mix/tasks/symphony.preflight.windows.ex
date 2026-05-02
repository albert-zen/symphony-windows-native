defmodule Mix.Tasks.Symphony.Preflight.Windows do
  @moduledoc """
  Runs Windows readiness checks for a Symphony workflow.

      mix symphony.preflight.windows WORKFLOW.windows.md
  """

  use Mix.Task

  alias SymphonyElixir.WindowsPreflight

  @shortdoc "Runs Windows Symphony preflight checks"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:req)

    {workflow_path, opts} =
      case parse_args(args) do
        {:ok, path, opts} -> {path, opts}
        {:error, :usage} -> Mix.raise("Usage: mix symphony.preflight.windows [--capabilities-only] [--json] [path-to-WORKFLOW.md]")
      end

    {status, checks} = WindowsPreflight.run(workflow_path, %{}, capabilities_only: Keyword.fetch!(opts, :capabilities_only))

    if Keyword.fetch!(opts, :json) do
      Mix.shell().info(WindowsPreflight.to_json(checks))
    else
      Mix.shell().info(WindowsPreflight.format(checks))
    end

    if status == :error do
      System.halt(1)
    end
  end

  @doc false
  @spec parse_args_for_test([String.t()]) :: {:ok, String.t(), keyword()} | {:error, :usage}
  def parse_args_for_test(args), do: parse_args(args)

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [capabilities_only: :boolean, json: :boolean]) do
      {opts, [], []} ->
        {:ok, "WORKFLOW.md", normalize_opts(opts)}

      {opts, [path], []} ->
        {:ok, path, normalize_opts(opts)}

      _ ->
        {:error, :usage}
    end
  end

  defp normalize_opts(opts) do
    [
      capabilities_only: Keyword.get(opts, :capabilities_only, false),
      json: Keyword.get(opts, :json, false)
    ]
  end
end
