defmodule SymphonyElixir.WindowsPreflightTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.WindowsPreflight

  test "reports passing checks for a ready Windows workflow" do
    workflow_path = workflow_with_preflight_config()

    deps = %{
      find_executable: fn _name -> "C:/tools/bin.exe" end,
      codex_command_resolves?: fn _command, _workspace_root -> :ok end,
      linear_graphql: fn _query, _variables ->
        {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}}
      end,
      local_shell_run: fn
        hook_probe, _opts when is_binary(hook_probe) ->
          cond do
            String.contains?(hook_probe, "[scriptblock]::Create") ->
              {:ok, {"hook after_create parsed\n7.5.0\n", 0}}

            String.starts_with?(hook_probe, "git clone --depth 1") ->
              {:ok, {"Cloning into preflight\n", 0}}

            hook_probe == "gh auth status" ->
              {:ok, {"Logged in\n", 0}}

            true ->
              flunk("unexpected command: #{hook_probe}")
          end
      end,
      port_available?: fn 4011 -> true end,
      start_codex_session: fn workspace ->
        assert File.dir?(workspace)
        :ok
      end
    }

    assert {:ok, checks} = WindowsPreflight.run(workflow_path, deps)
    assert Enum.all?(checks, &(&1.status in [:pass, :skip]))

    output = WindowsPreflight.format(checks)
    assert output =~ "[PASS] Linear auth"
    assert output =~ "[PASS] Codex app-server"
    assert output =~ "[PASS] Git repository"
    assert output =~ "[PASS] GitHub CLI"
    assert output =~ "[PASS] Dashboard port"
    assert output =~ "[PASS] PowerShell hooks"
  end

  test "returns an error and remediation when required checks fail" do
    workflow_path = workflow_with_preflight_config()

    deps = %{
      find_executable: fn
        "git" -> "C:/tools/git.exe"
        _name -> nil
      end,
      codex_command_resolves?: fn _command, _workspace_root -> {:error, :missing_codex} end,
      linear_graphql: fn _query, _variables -> {:error, :unauthorized} end,
      local_shell_run: fn
        hook_probe, _opts when is_binary(hook_probe) ->
          cond do
            String.contains?(hook_probe, "[scriptblock]::Create") -> {:ok, {"blocked", 1}}
            String.starts_with?(hook_probe, "git clone --depth 1") -> {:ok, {"denied", 128}}
            hook_probe == "gh auth status" -> {:ok, {"not logged in", 1}}
            true -> flunk("unexpected command: #{hook_probe}")
          end
      end,
      port_available?: fn 4011 -> false end,
      start_codex_session: fn _workspace -> {:error, :response_timeout} end
    }

    assert {:error, checks} = WindowsPreflight.run(workflow_path, deps)
    assert Enum.any?(checks, &(&1.status == :fail))

    output = WindowsPreflight.format(checks)
    assert output =~ "Fix: Verify LINEAR_API_KEY"
    assert output =~ "Missing required executable(s): gh, node"
    assert output =~ "gh auth status exited 1"
    assert output =~ "Port 4011 is already in use"
  end

  test "fails workflows that are not semantically ready for Linear dispatch" do
    workflow_path = workflow_with_preflight_config(tracker_project_slug: nil)

    deps = %{
      find_executable: fn _name -> "C:/tools/bin.exe" end,
      codex_command_resolves?: fn _command, _workspace_root -> :ok end,
      linear_graphql: fn _query, _variables ->
        {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}}
      end,
      local_shell_run: fn
        hook_probe, _opts when is_binary(hook_probe) ->
          cond do
            String.contains?(hook_probe, "[scriptblock]::Create") ->
              {:ok, {"hook after_create parsed\n7.5.0\n", 0}}

            String.starts_with?(hook_probe, "git clone --depth 1") ->
              {:ok, {"Cloning into preflight\n", 0}}

            hook_probe == "gh auth status" ->
              {:ok, {"Logged in\n", 0}}

            true ->
              flunk("unexpected command: #{hook_probe}")
          end
      end,
      port_available?: fn 4011 -> true end,
      start_codex_session: fn _workspace -> :ok end
    }

    assert {:error, checks} = WindowsPreflight.run(workflow_path, deps)

    assert %WindowsPreflight.Check{status: :fail, message: message} =
             Enum.find(checks, &(&1.name == "Workflow semantics"))

    assert message =~ ":missing_linear_project_slug"
  end

  defp workflow_with_preflight_config(overrides \\ []) do
    workflow_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-preflight-workflow-#{System.unique_integer([:positive])}.md"
      )

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-preflight-workspaces-#{System.unique_integer([:positive])}"
      )

    options =
      Keyword.merge(
        [
          workspace_root: workspace_root,
          hook_after_create: """
          $ErrorActionPreference = "Stop"
          git clone --depth 1 https://github.com/albert-zen/symphony-windows-native.git .
          """,
          server_port: 4011
        ],
        overrides
      )

    write_workflow_file!(workflow_path, options)

    workflow_path
  end
end
