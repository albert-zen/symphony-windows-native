defmodule SymphonyElixir.WindowsLifecycleScriptsTest do
  use SymphonyElixir.TestSupport, async: false

  @moduletag :windows_native

  defp powershell do
    Enum.find(["pwsh", "powershell"], fn command ->
      System.find_executable(command)
    end)
  end

  defp script_path(name) do
    Path.expand(Path.join(["scripts", name]))
  end

  defp shell_quote(path), do: "'" <> String.replace(path, "'", "''") <> "'"

  defp run_powershell!(args) do
    shell = powershell() || flunk("PowerShell executable not found")
    System.cmd(shell, args, stderr_to_stdout: true)
  end

  test "Windows lifecycle scripts parse in PowerShell" do
    for script <- [
          "start-windows-native.ps1",
          "stop-windows-native.ps1",
          "install-windows-native-service.ps1",
          "cleanup-windows-native.ps1"
        ] do
      command = "[scriptblock]::Create((Get-Content -Raw -LiteralPath #{shell_quote(script_path(script))})) | Out-Null"

      assert {"", 0} =
               run_powershell!([
                 "-NoProfile",
                 "-ExecutionPolicy",
                 "Bypass",
                 "-Command",
                 command
               ])
    end
  end

  test "cleanup removes only the requested issue workspace" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-lifecycle-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target = Path.join(workspace_root, "ALB_11")
      other = Path.join(workspace_root, "ALB-12")
      File.mkdir_p!(target)
      File.mkdir_p!(other)
      File.write!(Path.join(target, "marker.txt"), "remove")
      File.write!(Path.join(other, "marker.txt"), "keep")

      {_output, 0} =
        run_powershell!([
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          script_path("cleanup-windows-native.ps1"),
          "-WorkspaceRoot",
          workspace_root,
          "-IssueIdentifier",
          "ALB/11"
        ])

      refute File.exists?(target)
      assert File.exists?(Path.join(other, "marker.txt"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "cleanup refuses to treat the source checkout as a workspace root" do
    {_output, status} =
      run_powershell!([
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        script_path("cleanup-windows-native.ps1"),
        "-WorkspaceRoot",
        Path.expand("."),
        "-AllWorkspaces"
      ])

    assert status != 0
  end

  test "cleanup refuses issue identifiers that resolve to the workspace root" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-lifecycle-root-target-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(workspace_root, "marker.txt"), "keep")

      for issue_identifier <- [".", ".."] do
        {_output, status} =
          run_powershell!([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            script_path("cleanup-windows-native.ps1"),
            "-WorkspaceRoot",
            workspace_root,
            "-IssueIdentifier",
            issue_identifier
          ])

        assert status != 0
      end

      assert File.exists?(Path.join(workspace_root, "marker.txt"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "cleanup sanitizes traversal-like issue identifiers instead of leaving the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-lifecycle-traversal-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")

    try do
      sanitized_target = Path.join(workspace_root, ".._ALB-11")
      sibling = Path.join(test_root, "ALB-11")
      File.mkdir_p!(sanitized_target)
      File.mkdir_p!(sibling)
      File.write!(Path.join(sanitized_target, "marker.txt"), "remove")
      File.write!(Path.join(sibling, "marker.txt"), "keep")

      {_output, 0} =
        run_powershell!([
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          script_path("cleanup-windows-native.ps1"),
          "-WorkspaceRoot",
          workspace_root,
          "-IssueIdentifier",
          "../ALB-11"
        ])

      refute File.exists?(sanitized_target)
      assert File.exists?(Path.join(sibling, "marker.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "cleanup refuses to delete a checkout below the selected workspace root" do
    workspace_parent = Path.expand("..")

    {_output, status} =
      run_powershell!([
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        script_path("cleanup-windows-native.ps1"),
        "-WorkspaceRoot",
        workspace_parent,
        "-IssueIdentifier",
        Path.basename(Path.expand("."))
      ])

    assert status != 0
    assert File.exists?(Path.join(Path.expand("."), "mix.exs"))
  end

  test "cleanup resolves env-backed workspace root from workflow path" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-lifecycle-env-root-#{System.unique_integer([:positive])}"
      )

    workflow_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-lifecycle-env-workflow-#{System.unique_integer([:positive])}.md"
      )

    env_var = "SYMPHONY_LIFECYCLE_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    previous = System.get_env(env_var)

    try do
      target = Path.join(workspace_root, "ALB-11")
      File.mkdir_p!(target)
      File.write!(Path.join(target, "marker.txt"), "remove")
      System.put_env(env_var, workspace_root)

      File.write!(workflow_path, """
      ---
      workspace:
        root: $#{env_var}
      ---
      """)

      {_output, 0} =
        run_powershell!([
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          script_path("cleanup-windows-native.ps1"),
          "-WorkflowPath",
          workflow_path,
          "-IssueIdentifier",
          "ALB-11"
        ])

      refute File.exists?(target)
      refute File.exists?(Path.join(Path.expand("."), "$#{env_var}"))
    after
      restore_env(env_var, previous)
      File.rm_rf(workspace_root)
      File.rm(workflow_path)
    end
  end
end
