defmodule SymphonyElixir.Deployment.ReloadTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.Deployment.Reload

  defp runtime_info(logs_root, overrides \\ []) do
    repo_root = Path.join(logs_root, "repo")
    reload_script = Path.join([repo_root, "elixir", "scripts", "reload-windows-native.ps1"])
    File.mkdir_p!(Path.dirname(reload_script))
    File.write!(reload_script, "# test reload script\n")

    Map.merge(
      %{
        cwd: Path.join(repo_root, "elixir"),
        repo_root: repo_root,
        commit: "abc123",
        branch: "main",
        dirty?: false,
        workflow_path: Workflow.workflow_file_path(),
        logs_root: logs_root,
        pid_file: Path.join(logs_root, "symphony.pid.json"),
        port: 4011,
        os_pid: "999",
        started_at: "2026-01-01T00:00:00Z"
      },
      Map.new(overrides)
    )
  end

  defp request_opts(logs_root, overrides) do
    Keyword.merge(
      [
        runtime_info: runtime_info(logs_root),
        snapshot: %{running: []},
        start_fun: fn _payload -> :ok end,
        now_fun: fn -> ~U[2026-01-01 00:00:00Z] end,
        id_fun: fn -> "reload-#{System.unique_integer([:positive])}" end
      ],
      overrides
    )
  end

  test "request reports runtime and repository guard failures before starting" do
    logs_root = Path.join(System.tmp_dir!(), "symphony-reload-guards-#{System.unique_integer([:positive])}")

    try do
      assert {:error, :runtime_info_unavailable} =
               Reload.request(SymphonyElixir.Orchestrator, 5, request_opts(logs_root, runtime_info: %{}))

      assert {:error, :repo_root_unavailable} =
               Reload.request(
                 SymphonyElixir.Orchestrator,
                 5,
                 request_opts(logs_root, runtime_info: runtime_info(logs_root, repo_root: ""))
               )

      assert {:error, :dirty_repo} =
               Reload.request(
                 SymphonyElixir.Orchestrator,
                 5,
                 request_opts(logs_root, runtime_info: runtime_info(logs_root, dirty?: true))
               )

      assert {:error, :repo_status_unavailable} =
               Reload.request(
                 SymphonyElixir.Orchestrator,
                 5,
                 request_opts(logs_root, runtime_info: runtime_info(logs_root, dirty?: nil))
               )
    after
      File.rm_rf(logs_root)
    end
  end

  test "request records snapshot and helper start blockers" do
    logs_root = Path.join(System.tmp_dir!(), "symphony-reload-start-#{System.unique_integer([:positive])}")

    try do
      assert {:error, :snapshot_timeout} =
               Reload.request(SymphonyElixir.Orchestrator, 5, request_opts(logs_root, snapshot: :timeout))

      assert {:error, :snapshot_unavailable} =
               Reload.request(SymphonyElixir.Orchestrator, 5, request_opts(logs_root, snapshot: :unavailable))

      assert {:error, :helper_failed} =
               Reload.request(
                 SymphonyElixir.Orchestrator,
                 5,
                 request_opts(logs_root, start_fun: fn _payload -> {:error, :helper_failed} end)
               )

      assert {:error, :unexpected_helper_result} =
               Reload.request(
                 SymphonyElixir.Orchestrator,
                 5,
                 request_opts(logs_root,
                   force: true,
                   snapshot: :timeout,
                   start_fun: fn _payload -> :unexpected_helper_result end
                 )
               )
    after
      File.rm_rf(logs_root)
    end
  end

  test "latest status and active checks tolerate absent or invalid status files" do
    logs_root = Path.join(System.tmp_dir!(), "symphony-reload-status-#{System.unique_integer([:positive])}")

    try do
      assert Reload.latest_status(nil) == nil
      assert Reload.latest_status(logs_root) == nil
      assert Reload.active?(nil) == false
      assert Reload.active?(:not_a_path) == false

      status_dir = Path.join(logs_root, "reload")
      File.mkdir_p!(status_dir)
      File.write!(Path.join(status_dir, "done.json"), Jason.encode!(%{status: "done"}))

      assert %{"status" => "done"} = Reload.latest_status(logs_root)

      File.write!(Path.join(status_dir, "bad.json"), "not json")
      File.write!(Path.join(status_dir, "queued.json"), Jason.encode!(%{status: "queued"}))
      assert Reload.active?(logs_root) == true
    after
      File.rm_rf(logs_root)
    end
  end
end
