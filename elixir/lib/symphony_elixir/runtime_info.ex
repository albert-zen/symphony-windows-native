defmodule SymphonyElixir.RuntimeInfo do
  @moduledoc """
  Runtime metadata used by the dashboard and managed reload flow.
  """

  alias SymphonyElixir.{Config, Workflow}

  @type t :: %{
          cwd: Path.t(),
          repo_root: Path.t() | nil,
          commit: String.t() | nil,
          branch: String.t() | nil,
          dirty?: boolean() | nil,
          workflow_path: Path.t(),
          logs_root: Path.t() | nil,
          pid_file: Path.t() | nil,
          port: non_neg_integer() | nil,
          os_pid: String.t(),
          started_at: String.t() | nil
        }

  @type deps :: %{
          cwd: (-> Path.t()),
          git: ([String.t()], Path.t() -> {String.t(), non_neg_integer()})
        }

  @spec snapshot() :: t()
  @spec snapshot(deps()) :: t()
  def snapshot(deps \\ runtime_deps()) do
    cwd = deps.cwd.()
    repo_root = git_output(deps, ["rev-parse", "--show-toplevel"], cwd)
    git_cwd = repo_root || cwd

    %{
      cwd: cwd,
      repo_root: repo_root,
      commit: git_output(deps, ["rev-parse", "HEAD"], git_cwd),
      branch: git_output(deps, ["branch", "--show-current"], git_cwd) |> blank_to_nil(),
      dirty?: dirty?(deps, git_cwd),
      workflow_path: Workflow.workflow_file_path(),
      logs_root: Application.get_env(:symphony_elixir, :logs_root),
      pid_file: Application.get_env(:symphony_elixir, :pid_file),
      port: Config.server_port(),
      os_pid: System.pid(),
      started_at: Application.get_env(:symphony_elixir, :started_at)
    }
  end

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      cwd: &File.cwd!/0,
      git: fn args, cd -> System.cmd("git", args, cd: cd, stderr_to_stdout: true) end
    }
  end

  defp git_output(deps, args, cwd) do
    case deps.git.(args, cwd) do
      {output, 0} -> output |> String.trim() |> blank_to_nil()
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp dirty?(deps, cwd) do
    case deps.git.(["status", "--porcelain"], cwd) do
      {output, 0} -> String.trim(output) != ""
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
