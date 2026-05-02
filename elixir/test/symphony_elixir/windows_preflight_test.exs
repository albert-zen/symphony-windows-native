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
            line_ending_command?(hook_probe) ->
              ready_line_ending_response(hook_probe)

            git_main_tracking_command?(hook_probe) ->
              ready_git_main_tracking_response(hook_probe)

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

  test "capabilities-only reports machine-readable environment evidence without expensive probes" do
    workflow_path = workflow_with_preflight_config()

    deps =
      ready_deps(%{
        find_executable: fn
          "powershell" -> "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
          "tasklist" -> nil
          _name -> "C:/tools/bin.exe"
        end,
        os_type: fn -> {:win32, :nt} end,
        local_shell_run: fn
          "gh auth status", _opts ->
            {:ok, {"Logged in to github.com\n", 0}}

          command, _opts when is_binary(command) ->
            if line_ending_command?(command) do
              ready_line_ending_response(command)
            else
              flunk("capabilities-only should not run #{command}")
            end

          unexpected, _opts ->
            flunk("capabilities-only should not run #{unexpected}")
        end
      })

    assert {:ok, checks} = WindowsPreflight.run(workflow_path, deps, capabilities_only: true)

    names = Enum.map(checks, & &1.name)
    assert "Operating system" in names
    assert "PowerShell" in names
    assert "Windows tasklist" in names
    assert "GitHub CLI" in names
    assert "Linear auth" in names
    assert "Coverage policy" in names
    refute "Codex app-server" in names
    refute "Git repository" in names

    assert %WindowsPreflight.Check{status: :warn, remediation: remediation} =
             Enum.find(checks, &(&1.name == "Windows tasklist"))

    assert remediation =~ "graceful fallback"
  end

  test "JSON output redacts capability secrets and includes status labels" do
    workflow_path = workflow_with_preflight_config()

    deps =
      ready_deps(%{
        find_executable: fn
          "powershell" -> "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
          "tasklist" -> "C:/Windows/System32/tasklist.exe"
          _name -> "C:/tools/bin.exe"
        end,
        os_type: fn -> {:win32, :nt} end,
        env: fn
          "LINEAR_API_KEY" -> "lin_secret_token"
          _name -> nil
        end,
        local_shell_run: fn
          "gh auth status", _opts ->
            {:ok, {"Logged in with token ghp_secret\n", 0}}

          command, _opts when is_binary(command) ->
            if line_ending_command?(command) do
              ready_line_ending_response(command)
            else
              flunk("unexpected command: #{command}")
            end

          unexpected, _opts ->
            flunk("unexpected command: #{unexpected}")
        end
      })

    assert {:ok, checks} = WindowsPreflight.run(workflow_path, deps, capabilities_only: true)
    json = WindowsPreflight.to_json(checks)

    assert %{"checks" => encoded_checks} = Jason.decode!(json)
    assert Enum.any?(encoded_checks, &(&1["name"] == "Linear auth" and &1["status"] == "pass"))
    refute json =~ "lin_secret_token"
    refute json =~ "ghp_secret"
    assert json =~ "[redacted]"
  end

  test "default text output redacts failed GitHub auth details" do
    workflow_path = workflow_with_preflight_config()

    deps =
      ready_deps(%{
        find_executable: fn _name -> "C:/tools/bin.exe" end,
        local_shell_run: fn
          "gh auth status", _opts ->
            {:ok, {"failed with ghp_secret and https://token:secret@github.com/example/repo.git", 1}}

          command, _opts when is_binary(command) ->
            if line_ending_command?(command) do
              ready_line_ending_response(command)
            else
              flunk("unexpected command: #{command}")
            end

          unexpected, _opts ->
            flunk("unexpected command: #{unexpected}")
        end
      })

    assert {:error, checks} = WindowsPreflight.run(workflow_path, deps, capabilities_only: true)
    output = WindowsPreflight.format(checks)

    refute output =~ "ghp_secret"
    refute output =~ "token"
    refute output =~ "secret"
    assert output =~ "[redacted]"
  end

  test "warns when repo autocrlf is true but formatter-managed files are LF-normalized" do
    workflow_path = workflow_with_preflight_config()

    deps =
      ready_deps(%{
        local_shell_run: fn
          command, _opts when is_binary(command) ->
            cond do
              line_ending_command?(command) ->
                ready_line_ending_response(command, core_autocrlf: "true")

              command == "gh auth status" ->
                {:ok, {"Logged in\n", 0}}

              true ->
                flunk("unexpected command: #{command}")
            end
        end
      })

    assert {:ok, checks} = WindowsPreflight.run(workflow_path, deps, capabilities_only: true)

    assert %WindowsPreflight.Check{status: :warn, message: message, remediation: remediation} =
             Enum.find(checks, &(&1.name == "Git line endings"))

    assert message =~ "core.autocrlf=true"
    assert message =~ "no formatter-managed files are checked out as CRLF"
    assert remediation =~ "git config --local core.autocrlf false"
  end

  test "warns when effective autocrlf is true from global config" do
    workflow_path = workflow_with_preflight_config()

    deps =
      ready_deps(%{
        local_shell_run: fn
          command, _opts when is_binary(command) ->
            cond do
              line_ending_command?(command) ->
                ready_line_ending_response(command,
                  local_core_autocrlf: nil,
                  effective_core_autocrlf: "true"
                )

              command == "gh auth status" ->
                {:ok, {"Logged in\n", 0}}

              true ->
                flunk("unexpected command: #{command}")
            end
        end
      })

    assert {:ok, checks} = WindowsPreflight.run(workflow_path, deps, capabilities_only: true)

    assert %WindowsPreflight.Check{status: :warn, message: message, remediation: remediation} =
             Enum.find(checks, &(&1.name == "Git line endings"))

    assert message =~ "core.autocrlf=true"
    assert message =~ "effective Git config"
    assert remediation =~ "git config --local core.autocrlf false"
  end

  test "fails when formatter-managed files are checked out with CRLF worktree endings" do
    workflow_path = workflow_with_preflight_config()

    deps =
      ready_deps(%{
        local_shell_run: fn
          command, _opts when is_binary(command) ->
            cond do
              line_ending_command?(command) ->
                ready_line_ending_response(command,
                  core_autocrlf: "false",
                  eol_output: """
                  i/lf    w/lf    attr/text eol=lf      \t.gitattributes
                  i/lf    w/crlf  attr/text eol=lf      \telixir/lib/symphony_elixir/windows_preflight.ex
                  i/lf    w/lf    attr/text eol=lf      \telixir/docs/windows-native.md
                  """
                )

              command == "gh auth status" ->
                {:ok, {"Logged in\n", 0}}

              true ->
                flunk("unexpected command: #{command}")
            end
        end
      })

    assert {:error, checks} = WindowsPreflight.run(workflow_path, deps, capabilities_only: true)

    assert %WindowsPreflight.Check{status: :fail, message: message, remediation: remediation} =
             Enum.find(checks, &(&1.name == "Git line endings"))

    assert message =~ "formatter-managed files are checked out as CRLF"
    assert message =~ "elixir/lib/symphony_elixir/windows_preflight.ex"
    assert remediation =~ "git add --renormalize"
  end

  test "fails when repo attributes do not force formatter-managed files to LF" do
    workflow_path = workflow_with_preflight_config()

    deps =
      ready_deps(%{
        local_shell_run: fn
          command, _opts when is_binary(command) ->
            cond do
              line_ending_command?(command) ->
                ready_line_ending_response(command,
                  attr_output: """
                  .gitattributes: eol: lf
                  elixir/.formatter.exs: eol: lf
                  elixir/.gitattributes: eol: lf
                  elixir/mix.exs: eol: unspecified
                  elixir/docs/windows-native.md: eol: lf
                  .github/workflows/make-all.yml: eol: lf
                  """
                )

              command == "gh auth status" ->
                {:ok, {"Logged in\n", 0}}

              true ->
                flunk("unexpected command: #{command}")
            end
        end
      })

    assert {:error, checks} = WindowsPreflight.run(workflow_path, deps, capabilities_only: true)

    assert %WindowsPreflight.Check{status: :fail, message: message, remediation: remediation} =
             Enum.find(checks, &(&1.name == "Git line endings"))

    assert message =~ "missing LF coverage"
    assert message =~ "elixir/mix.exs"
    assert remediation =~ ".gitattributes"
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
            line_ending_command?(hook_probe) ->
              ready_line_ending_response(hook_probe)

            git_main_tracking_command?(hook_probe) ->
              ready_git_main_tracking_response(hook_probe)

            String.contains?(hook_probe, "[scriptblock]::Create") ->
              {:ok, {"blocked", 1}}

            String.starts_with?(hook_probe, "git clone --depth 1") ->
              {:ok, {"denied", 128}}

            hook_probe == "gh auth status" ->
              {:ok, {"not logged in", 1}}

            true ->
              flunk("unexpected command: #{hook_probe}")
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
            line_ending_command?(hook_probe) ->
              ready_line_ending_response(hook_probe)

            git_main_tracking_command?(hook_probe) ->
              ready_git_main_tracking_response(hook_probe)

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

  test "redacts credential-bearing clone URLs from preflight output" do
    workflow_path =
      workflow_with_preflight_config(
        hook_after_create: """
        git clone 'https://token:secret@github.com/albert-zen/symphony-windows-native.git' .
        """
      )

    deps =
      ready_deps(%{
        local_shell_run: fn
          command, _opts when is_binary(command) ->
            cond do
              line_ending_command?(command) ->
                ready_line_ending_response(command)

              git_main_tracking_command?(command) ->
                ready_git_main_tracking_response(command)

              String.contains?(command, "[scriptblock]::Create") ->
                {:ok, {"hook after_create parsed\n7.5.0\n", 0}}

              String.starts_with?(command, "git clone --depth 1") ->
                {:ok, {"fatal: could not read from https://token:secret@github.com/albert-zen/symphony-windows-native.git", 128}}

              command == "gh auth status" ->
                {:ok, {"Logged in\n", 0}}

              true ->
                flunk("unexpected command: #{command}")
            end
        end
      })

    assert {:error, checks} = WindowsPreflight.run(workflow_path, deps)

    output = WindowsPreflight.format(checks)
    refute output =~ "token"
    refute output =~ "secret"
    assert output =~ "https://[redacted]@github.com/albert-zen/symphony-windows-native.git"
  end

  test "redacts credential-bearing clone URLs from PowerShell hook parse output" do
    workflow_path =
      workflow_with_preflight_config(
        hook_after_create: """
        git clone "https://token:secret@github.com/albert-zen/symphony-windows-native.git" .
        """
      )

    deps =
      ready_deps(%{
        local_shell_run: fn
          command, _opts when is_binary(command) ->
            cond do
              line_ending_command?(command) ->
                ready_line_ending_response(command)

              git_main_tracking_command?(command) ->
                ready_git_main_tracking_response(command)

              String.contains?(command, "[scriptblock]::Create") ->
                {:ok, {"At line:1 char:1 git clone https://token:secret@github.com/albert-zen/symphony-windows-native.git", 1}}

              String.starts_with?(command, "git clone --depth 1") ->
                {:ok, {"Cloning into preflight\n", 0}}

              command == "gh auth status" ->
                {:ok, {"Logged in\n", 0}}

              true ->
                flunk("unexpected command: #{command}")
            end
        end
      })

    assert {:error, checks} = WindowsPreflight.run(workflow_path, deps)

    output = WindowsPreflight.format(checks)
    refute output =~ "token"
    refute output =~ "secret"
    assert output =~ "https://[redacted]@github.com/albert-zen/symphony-windows-native.git"
  end

  test "validates a fresh workspace root before cloning into it" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-preflight-fresh-root-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workspace_root)

    workflow_path = workflow_with_preflight_config(workspace_root: workspace_root)

    deps =
      ready_deps(%{
        start_codex_session: fn workspace ->
          assert File.dir?(workspace)
          File.rm_rf!(workspace_root)
          :ok
        end,
        local_shell_run: fn
          command, _opts when is_binary(command) ->
            cond do
              line_ending_command?(command) ->
                ready_line_ending_response(command)

              git_main_tracking_command?(command) ->
                ready_git_main_tracking_response(command)

              String.contains?(command, "[scriptblock]::Create") ->
                {:ok, {"hook after_create parsed\n7.5.0\n", 0}}

              String.starts_with?(command, "git clone --depth 1") ->
                assert File.dir?(workspace_root)
                {:ok, {"Cloning into preflight\n", 0}}

              command == "gh auth status" ->
                {:ok, {"Logged in\n", 0}}

              true ->
                flunk("unexpected command: #{command}")
            end
        end
      })

    assert {:ok, checks} = WindowsPreflight.run(workflow_path, deps)
    assert %WindowsPreflight.Check{status: :pass} = Enum.find(checks, &(&1.name == "Workspace root"))
    assert %WindowsPreflight.Check{status: :pass} = Enum.find(checks, &(&1.name == "Git repository"))
  end

  test "warns when local main tracks a noncanonical stale remote while origin main is newer" do
    workflow_path = workflow_with_preflight_config()
    Process.put(:fetched_origin_main, false)

    deps =
      ready_deps(%{
        local_shell_run: fn
          command, _opts when is_binary(command) ->
            cond do
              line_ending_command?(command) ->
                ready_line_ending_response(command)

              command == "git rev-parse --show-toplevel" ->
                {:ok, {"C:/repo/symphony-windows-native\n", 0}}

              String.contains?(command, "fetch origin main") ->
                Process.put(:fetched_origin_main, true)
                {:ok, {"From https://github.com/albert-zen/symphony-windows-native\n", 0}}

              String.contains?(command, "rev-parse --verify main") ->
                {:ok, {"local-main-sha\n", 0}}

              String.contains?(command, "rev-parse --verify origin/main") ->
                assert Process.get(:fetched_origin_main)
                {:ok, {"origin-main-sha\n", 0}}

              String.contains?(command, "rev-parse --abbrev-ref main@{upstream}") ->
                {:ok, {"windows/main\n", 0}}

              String.contains?(command, "merge-base --is-ancestor main origin/main") ->
                {:ok, {"", 0}}

              String.contains?(command, "[scriptblock]::Create") ->
                {:ok, {"hook after_create parsed\n7.5.0\n", 0}}

              String.starts_with?(command, "git clone --depth 1") ->
                {:ok, {"Cloning into preflight\n", 0}}

              command == "gh auth status" ->
                {:ok, {"Logged in\n", 0}}

              true ->
                flunk("unexpected command: #{command}")
            end
        end
      })

    assert {:ok, checks} = WindowsPreflight.run(workflow_path, deps)

    assert %WindowsPreflight.Check{status: :warn, message: message, remediation: remediation} =
             Enum.find(checks, &(&1.name == "Git main remote"))

    assert message =~ "tracks windows/main"
    assert message =~ "origin/main is newer"
    assert remediation =~ "git branch --set-upstream-to=origin/main main"
    assert WindowsPreflight.format(checks) =~ "[WARN] Git main remote"
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

  defp ready_deps(overrides) do
    Map.merge(
      %{
        find_executable: fn _name -> "C:/tools/bin.exe" end,
        codex_command_resolves?: fn _command, _workspace_root -> :ok end,
        linear_graphql: fn _query, _variables ->
          {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}}
        end,
        port_available?: fn 4011 -> true end,
        start_codex_session: fn workspace ->
          assert File.dir?(workspace)
          :ok
        end
      },
      overrides
    )
  end

  defp git_main_tracking_command?(command) do
    command == "git rev-parse --show-toplevel" or
      String.contains?(command, "fetch origin main") or
      String.contains?(command, "rev-parse --verify main") or
      String.contains?(command, "rev-parse --verify origin/main") or
      String.contains?(command, "rev-parse --abbrev-ref main@{upstream}") or
      String.contains?(command, "merge-base --is-ancestor main origin/main")
  end

  defp line_ending_command?(command) do
    command == "git rev-parse --show-toplevel" or
      (String.contains?(command, "git -C") and
         (String.contains?(command, "config --local --get core.autocrlf") or
            String.contains?(command, "config --get core.autocrlf") or
            String.contains?(command, "ls-files --eol") or
            String.contains?(command, "check-attr eol --")))
  end

  defp ready_line_ending_response(command, opts \\ []) do
    local_core_autocrlf = Keyword.get(opts, :local_core_autocrlf, Keyword.get(opts, :core_autocrlf, "false"))
    effective_core_autocrlf = Keyword.get(opts, :effective_core_autocrlf, local_core_autocrlf || "false")

    eol_output =
      Keyword.get(opts, :eol_output, """
      i/lf    w/lf    attr/text eol=lf      \t.gitattributes
      i/lf    w/lf    attr/text eol=lf      \telixir/lib/symphony_elixir/windows_preflight.ex
      i/lf    w/lf    attr/text eol=lf      \telixir/docs/windows-native.md
      """)

    attr_output =
      Keyword.get(opts, :attr_output, """
      .gitattributes: eol: lf
      elixir/.formatter.exs: eol: lf
      elixir/.gitattributes: eol: lf
      elixir/mix.exs: eol: lf
      elixir/docs/windows-native.md: eol: lf
      .github/workflows/make-all.yml: eol: lf
      """)

    cond do
      command == "git rev-parse --show-toplevel" ->
        {:ok, {"C:/repo/symphony-windows-native\n", 0}}

      String.contains?(command, "config --local --get core.autocrlf") ->
        case local_core_autocrlf do
          nil -> {:ok, {"", 1}}
          value -> {:ok, {value <> "\n", 0}}
        end

      String.contains?(command, "config --get core.autocrlf") ->
        {:ok, {effective_core_autocrlf <> "\n", 0}}

      String.contains?(command, "ls-files --eol") ->
        {:ok, {eol_output, 0}}

      String.contains?(command, "check-attr eol --") ->
        {:ok, {attr_output, 0}}
    end
  end

  defp ready_git_main_tracking_response("git rev-parse --show-toplevel") do
    {:ok, {"C:/repo/symphony-windows-native\n", 0}}
  end

  defp ready_git_main_tracking_response(command) do
    cond do
      String.contains?(command, "fetch origin main") ->
        {:ok, {"From https://github.com/albert-zen/symphony-windows-native\n", 0}}

      String.contains?(command, "rev-parse --verify main") ->
        {:ok, {"main-sha\n", 0}}

      String.contains?(command, "rev-parse --verify origin/main") ->
        {:ok, {"main-sha\n", 0}}

      String.contains?(command, "rev-parse --abbrev-ref main@{upstream}") ->
        {:ok, {"origin/main\n", 0}}

      String.contains?(command, "merge-base --is-ancestor main origin/main") ->
        {:ok, {"", 1}}
    end
  end
end
