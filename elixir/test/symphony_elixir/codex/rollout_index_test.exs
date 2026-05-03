defmodule SymphonyElixir.Codex.RolloutIndexTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.RolloutIndex

  setup do
    base = Path.join(System.tmp_dir!(), "rollout-index-#{System.unique_integer([:positive])}")
    sessions_root = Path.join(base, "sessions")
    workspace_root = Path.join(base, "workspaces")
    File.mkdir_p!(sessions_root)
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, sessions_root: sessions_root, workspace_root: workspace_root}
  end

  defp write_rollout!(sessions_root, opts) do
    opts = Enum.into(opts, %{})
    cwd = Map.fetch!(opts, :cwd)
    session_id = Map.fetch!(opts, :session_id)
    started_at = Map.get(opts, :started_at, "2026-05-02T10:43:30.000Z")

    date_dir = Path.join([sessions_root, "2026", "05", "02"])
    File.mkdir_p!(date_dir)

    path =
      Path.join(date_dir, "rollout-2026-05-02T#{:os.system_time(:nanosecond)}-#{session_id}.jsonl")

    line =
      Jason.encode!(%{
        "timestamp" => started_at,
        "type" => "session_meta",
        "payload" => %{
          "id" => session_id,
          "cwd" => cwd,
          "originator" => "Codex",
          "cli_version" => "0.128.0",
          "model_provider" => "openai",
          "timestamp" => started_at
        }
      })

    File.write!(path, line <> "\n")
    path
  end

  defp start_index!(opts) do
    name = :"rollout_index_#{System.unique_integer([:positive])}"
    {:ok, _pid} = RolloutIndex.start_link(Keyword.put(opts, :name, name))
    name
  end

  describe "lookup/1" do
    test "groups rollouts by issue identifier from cwd basename and sorts newest-first",
         %{sessions_root: sessions_root, workspace_root: workspace_root} do
      alb_workspace = Path.join(workspace_root, "ALB-39")
      File.mkdir_p!(alb_workspace)

      _old =
        write_rollout!(sessions_root,
          cwd: alb_workspace,
          session_id: "old-session",
          started_at: "2026-05-01T10:00:00Z"
        )

      _new =
        write_rollout!(sessions_root,
          cwd: alb_workspace,
          session_id: "new-session",
          started_at: "2026-05-02T10:00:00Z"
        )

      name = start_index!(sessions_root: sessions_root, workspace_root: workspace_root)

      entries = RolloutIndex.lookup("ALB-39", name: name)
      assert length(entries) == 2
      assert [first, second] = entries
      assert first.session_id == "new-session"
      assert second.session_id == "old-session"
      assert first.issue_identifier == "ALB-39"
    end

    test "filters out rollouts whose cwd is outside the configured workspace root",
         %{sessions_root: sessions_root, workspace_root: workspace_root} do
      # Inside workspace root
      inside = Path.join(workspace_root, "ALB-1")
      File.mkdir_p!(inside)
      write_rollout!(sessions_root, cwd: inside, session_id: "in-1")

      # Outside workspace root (e.g. user opened Codex Desktop on a personal repo)
      outside = Path.join(System.tmp_dir!(), "unrelated-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)
      write_rollout!(sessions_root, cwd: outside, session_id: "out-1")

      name = start_index!(sessions_root: sessions_root, workspace_root: workspace_root)

      assert [%{session_id: "in-1"}] = RolloutIndex.lookup("ALB-1", name: name)
      assert RolloutIndex.lookup(Path.basename(outside), name: name) == []
    end

    test "returns [] for unknown issue identifiers",
         %{sessions_root: sessions_root, workspace_root: workspace_root} do
      name = start_index!(sessions_root: sessions_root, workspace_root: workspace_root)
      assert RolloutIndex.lookup("DOES-NOT-EXIST", name: name) == []
    end

    test "returns [] when the index process is not running" do
      assert RolloutIndex.lookup("ALB-1", name: :rollout_index_unstarted_xyz) == []
    end
  end

  describe "refresh/0" do
    test "picks up rollouts created after init",
         %{sessions_root: sessions_root, workspace_root: workspace_root} do
      alb_workspace = Path.join(workspace_root, "ALB-7")
      File.mkdir_p!(alb_workspace)

      name = start_index!(sessions_root: sessions_root, workspace_root: workspace_root)
      assert RolloutIndex.lookup("ALB-7", name: name) == []

      write_rollout!(sessions_root, cwd: alb_workspace, session_id: "fresh-session")

      assert :ok = RolloutIndex.refresh(name: name)
      assert [%{session_id: "fresh-session"}] = RolloutIndex.lookup("ALB-7", name: name)
    end
  end

  describe "derive_issue_identifier/2" do
    test "returns nil for nil cwd" do
      assert RolloutIndex.derive_issue_identifier(nil, "/tmp") == nil
    end

    test "returns the basename when cwd is under the workspace root (case-insensitive)" do
      assert RolloutIndex.derive_issue_identifier("D:/Workspaces/ALB-3", "d:/workspaces") == "ALB-3"
    end

    test "returns nil when cwd is outside the workspace root" do
      assert RolloutIndex.derive_issue_identifier("/elsewhere/ALB-3", "/tmp/workspaces") == nil
    end

    test "sanitizes characters outside [A-Za-z0-9._-]" do
      assert RolloutIndex.derive_issue_identifier("/ws/foo bar", "/ws") == "foo_bar"
    end

    test "passes through when no workspace root configured" do
      assert RolloutIndex.derive_issue_identifier("/anywhere/ALB-9", nil) == "ALB-9"
    end
  end
end
