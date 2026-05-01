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

    workflow_path =
      case args do
        [] -> "WORKFLOW.md"
        [path] -> path
        _ -> Mix.raise("Usage: mix symphony.preflight.windows [path-to-WORKFLOW.md]")
      end

    {status, checks} = WindowsPreflight.run(workflow_path)

    Mix.shell().info(WindowsPreflight.format(checks))

    if status == :error do
      System.halt(1)
    end
  end
end
