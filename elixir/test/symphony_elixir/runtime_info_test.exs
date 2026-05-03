defmodule SymphonyElixir.RuntimeInfoTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.RuntimeInfo

  test "snapshots runtime metadata from git and application environment" do
    Application.put_env(:symphony_elixir, :logs_root, "D:/logs")
    Application.put_env(:symphony_elixir, :pid_file, "D:/logs/symphony.pid.json")
    Application.put_env(:symphony_elixir, :started_at, "2026-01-01T00:00:00Z")
    Application.put_env(:symphony_elixir, :server_port_override, 4011)

    deps = %{
      cwd: fn -> "D:/repo/elixir" end,
      git: fn
        ["rev-parse", "--show-toplevel"], "D:/repo/elixir" -> {"D:/repo\n", 0}
        ["rev-parse", "HEAD"], "D:/repo" -> {"abc123\n", 0}
        ["branch", "--show-current"], "D:/repo" -> {"\n", 0}
        ["status", "--porcelain"], "D:/repo" -> {" M lib/example.ex\n", 0}
      end
    }

    assert %{
             cwd: "D:/repo/elixir",
             repo_root: "D:/repo",
             commit: "abc123",
             branch: nil,
             dirty?: true,
             workflow_path: workflow_path,
             logs_root: "D:/logs",
             pid_file: "D:/logs/symphony.pid.json",
             port: 4011,
             started_at: "2026-01-01T00:00:00Z"
           } = RuntimeInfo.snapshot(deps)

    assert workflow_path == Workflow.workflow_file_path()
  end

  test "snapshots unavailable git metadata without crashing" do
    deps = %{
      cwd: fn -> "D:/repo/elixir" end,
      git: fn
        ["rev-parse", "--show-toplevel"], "D:/repo/elixir" -> {"fatal: not a repo", 128}
        ["rev-parse", "HEAD"], "D:/repo/elixir" -> raise "git unavailable"
        ["branch", "--show-current"], "D:/repo/elixir" -> {"", 1}
        ["status", "--porcelain"], "D:/repo/elixir" -> {"", 1}
      end
    }

    assert %{
             repo_root: nil,
             commit: nil,
             branch: nil,
             dirty?: nil
           } = RuntimeInfo.snapshot(deps)
  end
end
