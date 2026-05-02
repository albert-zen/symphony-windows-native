defmodule SymphonyElixir.WindowsPreflight do
  @moduledoc """
  Windows operator preflight checks for a Symphony workflow.
  """

  alias SymphonyElixir.{Codex.AppServer, Config, Linear.Client, LocalShell, Workflow}

  defmodule Check do
    @moduledoc false
    defstruct [:name, :status, :message, :remediation]
  end

  @type check_status :: :pass | :fail | :skip | :warn
  @type check :: %Check{
          name: String.t(),
          status: check_status(),
          message: String.t(),
          remediation: String.t() | nil
        }

  @type deps :: %{
          optional(:codex_command_resolves?) => (String.t(), Path.t() -> :ok | {:error, term()}),
          optional(:find_executable) => (String.t() -> String.t() | nil),
          optional(:linear_graphql) => (String.t(), map() -> {:ok, map()} | {:error, term()}),
          optional(:local_shell_run) => (String.t(), keyword() -> LocalShell.run_result()),
          optional(:port_available?) => (non_neg_integer() -> boolean()),
          optional(:start_codex_session) => (Path.t() -> :ok | {:error, term()})
        }

  @linear_viewer_query """
  query SymphonyPreflightViewer {
    viewer {
      id
    }
  }
  """

  @required_path_tools ["git", "gh", "node"]

  @spec run(Path.t(), deps()) :: {:ok | :error, [check()]}
  def run(workflow_path, deps \\ %{}) when is_binary(workflow_path) and is_map(deps) do
    expanded_path = Path.expand(workflow_path)
    Workflow.set_workflow_file_path(expanded_path)

    checks =
      case Config.settings() do
        {:ok, settings} ->
          [
            workflow_check(expanded_path),
            workflow_semantics_check(),
            linear_check(settings, deps),
            path_tools_check(settings, deps),
            github_cli_check(deps),
            git_main_tracking_check(deps),
            codex_app_server_check(settings, deps),
            workspace_root_check(settings),
            git_clone_check(settings, deps),
            dashboard_port_check(settings, deps),
            powershell_hooks_check(settings, deps)
          ]

        {:error, reason} ->
          [
            fail(
              "Workflow config",
              "Could not load #{expanded_path}: #{inspect(reason)}",
              "Pass a readable WORKFLOW.md path and fix YAML/front matter validation errors."
            )
          ]
      end

    status = if Enum.any?(checks, &(&1.status == :fail)), do: :error, else: :ok
    {status, checks}
  end

  @spec format([check()]) :: String.t()
  def format(checks) when is_list(checks) do
    checks
    |> Enum.map_join("\n", fn check ->
      suffix =
        case check.remediation do
          nil -> ""
          remediation -> "\n    Fix: " <> remediation
        end

      "[#{status_label(check.status)}] #{check.name}: #{check.message}" <> suffix
    end)
  end

  defp workflow_check(path) do
    pass("Workflow config", "Loaded #{path}.")
  end

  defp workflow_semantics_check do
    case Config.validate!() do
      :ok ->
        pass("Workflow semantics", "Required tracker settings are present.")

      {:error, reason} ->
        fail(
          "Workflow semantics",
          "Workflow is not dispatch-ready: #{inspect(reason)}",
          "Set tracker.kind, tracker.project_slug, and the required tracker credentials for the selected tracker."
        )
    end
  end

  defp linear_check(settings, deps) do
    cond do
      settings.tracker.kind != "linear" ->
        skip("Linear auth", "Tracker kind is #{inspect(settings.tracker.kind)}, not linear.")

      is_nil(settings.tracker.api_key) ->
        fail(
          "Linear auth",
          "tracker.api_key did not resolve to a Linear token.",
          "Set LINEAR_API_KEY or the environment variable referenced by tracker.api_key, then reload PowerShell."
        )

      true ->
        linear_graphql = Map.get(deps, :linear_graphql, &Client.graphql/2)

        case linear_graphql.(@linear_viewer_query, %{}) do
          {:ok, %{"data" => %{"viewer" => %{"id" => viewer_id}}}} when is_binary(viewer_id) ->
            pass("Linear auth", "Linear GraphQL is reachable for viewer #{viewer_id}.")

          {:ok, body} ->
            fail(
              "Linear auth",
              "Linear GraphQL returned an unexpected response: #{inspect(body)}",
              "Verify LINEAR_API_KEY has access to the configured Linear workspace."
            )

          {:error, reason} ->
            fail(
              "Linear auth",
              "Linear GraphQL request failed: #{inspect(reason)}",
              "Verify LINEAR_API_KEY, network access, and tracker.endpoint."
            )
        end
    end
  end

  defp path_tools_check(settings, deps) do
    find_executable = Map.get(deps, :find_executable, &System.find_executable/1)
    missing = Enum.reject(@required_path_tools, &find_executable.(&1))

    codex_command_resolves? =
      Map.get(deps, :codex_command_resolves?, fn command, workspace_root ->
        command
        |> LocalShell.port_args(cd: workspace_root)
        |> case do
          {:ok, _executable, _args} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end)

    codex_resolution = codex_command_resolves?.(settings.codex.command, settings.workspace.root)

    cond do
      missing != [] ->
        fail(
          "PATH tools",
          "Missing required executable(s): #{Enum.join(missing, ", ")}.",
          "Install the missing tools and make sure the current PowerShell session inherits PATH."
        )

      match?({:error, _reason}, codex_resolution) ->
        {:error, reason} = codex_resolution

        fail(
          "PATH tools",
          "Codex command could not be resolved for direct app-server startup: #{inspect(reason)}",
          "Ensure codex and node.exe are on PATH; npm shims such as codex.cmd must resolve to Node."
        )

      true ->
        pass("PATH tools", "git, gh, node, and the Codex app-server command are resolvable.")
    end
  end

  defp codex_app_server_check(settings, deps) do
    start_codex_session =
      Map.get(deps, :start_codex_session, fn workspace ->
        case AppServer.start_session(workspace, strict_stdio: true) do
          {:ok, session} ->
            AppServer.stop_session(session)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end)

    workspace = preflight_workspace(settings.workspace.root)

    try do
      with :ok <- File.mkdir_p(workspace),
           :ok <- start_codex_session.(workspace) do
        pass("Codex app-server", "Started codex app-server with clean JSON-RPC stdio.")
      else
        {:error, reason} ->
          fail(
            "Codex app-server",
            "Could not start a Codex app-server session with clean JSON-RPC stdio: #{inspect(reason)}",
            "Run `codex app-server` manually, confirm Codex is logged in, and avoid shell wrappers that write banners, warnings, or logs to stdio."
          )
      end
    after
      File.rm_rf(workspace)
    end
  end

  defp github_cli_check(deps) do
    local_shell_run = Map.get(deps, :local_shell_run, &LocalShell.run/2)

    case local_shell_run.("gh auth status", cd: File.cwd!()) do
      {:ok, {_output, 0}} ->
        pass("GitHub CLI", "gh is authenticated.")

      {:ok, {output, status}} ->
        fail(
          "GitHub CLI",
          "gh auth status exited #{status}: #{String.trim(output)}",
          "Run `gh auth login` for the Windows user that runs Symphony."
        )

      {:error, reason} ->
        fail(
          "GitHub CLI",
          "Could not run gh auth status: #{inspect(reason)}",
          "Install GitHub CLI and make sure gh.exe is on PATH."
        )
    end
  end

  defp git_main_tracking_check(deps) do
    local_shell_run = Map.get(deps, :local_shell_run, &LocalShell.run/2)

    with {:ok, repo_root} <- git_output(local_shell_run, "git rev-parse --show-toplevel", File.cwd!()),
         {:ok, _fetch_output} <- git_output(local_shell_run, "git -C #{shell_quote(repo_root)} fetch origin main", repo_root),
         {:ok, main_sha} <- git_output(local_shell_run, "git -C #{shell_quote(repo_root)} rev-parse --verify main", repo_root),
         {:ok, origin_main_sha} <-
           git_output(local_shell_run, "git -C #{shell_quote(repo_root)} rev-parse --verify origin/main", repo_root),
         {:ok, upstream} <-
           git_output(local_shell_run, "git -C #{shell_quote(repo_root)} rev-parse --abbrev-ref main@{upstream}", repo_root) do
      cond do
        upstream == "origin/main" ->
          pass("Git main remote", "Local main tracks canonical origin/main.")

        main_sha != origin_main_sha and git_ancestor?(local_shell_run, repo_root, "main", "origin/main") ->
          warn(
            "Git main remote",
            "Local main tracks #{upstream}, but canonical origin/main is newer.",
            "Run manager-side stale-base checks against origin/main or reconfigure local main with `git branch --set-upstream-to=origin/main main`."
          )

        true ->
          pass(
            "Git main remote",
            "Canonical GitHub ref is origin/main; local main currently tracks #{upstream}."
          )
      end
    else
      {:missing_ref, ref} ->
        skip("Git main remote", "Could not inspect #{ref}; run preflight from a checkout with local main and origin/main.")

      {:error, reason} ->
        skip("Git main remote", "Could not inspect local main tracking: #{inspect(reason)}.")
    end
  end

  defp git_output(local_shell_run, command, cwd) do
    case local_shell_run.(command, cd: cwd) do
      {:ok, {output, 0}} ->
        {:ok, String.trim(output)}

      {:ok, {output, status}} ->
        cond do
          String.contains?(command, "rev-parse --verify main") ->
            {:missing_ref, "main"}

          String.contains?(command, "rev-parse --verify origin/main") ->
            {:missing_ref, "origin/main"}

          true ->
            {:error, {command, status, sanitize_command_output(output)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp git_ancestor?(local_shell_run, repo_root, ancestor, descendant) do
    command = "git -C #{shell_quote(repo_root)} merge-base --is-ancestor #{ancestor} #{descendant}"

    case local_shell_run.(command, cd: repo_root) do
      {:ok, {_output, 0}} -> true
      {:ok, {_output, _status}} -> false
      {:error, _reason} -> false
    end
  end

  defp git_clone_check(settings, deps) do
    case configured_clone_url(settings.hooks.after_create) do
      nil ->
        skip(
          "Git repository",
          "No `git clone` URL was found in hooks.after_create."
        )

      clone_url ->
        local_shell_run = Map.get(deps, :local_shell_run, &LocalShell.run/2)

        clone_target = preflight_clone_target(settings.workspace.root)

        try do
          File.rm_rf(clone_target)

          case local_shell_run.("git clone --depth 1 #{shell_quote(clone_url)} #{shell_quote(clone_target)}", cd: File.cwd!()) do
            {:ok, {_output, 0}} ->
              pass("Git repository", "Git can clone #{redact_url(clone_url)}.")

            {:ok, {output, status}} ->
              fail(
                "Git repository",
                "Git clone check failed with exit #{status}: #{sanitize_command_output(output)}",
                "Verify repository URL, GitHub credentials, network access, and clone hooks before starting Symphony."
              )

            {:error, reason} ->
              fail(
                "Git repository",
                "Could not run git clone check: #{inspect(reason)}",
                "Install Git and make sure it is available to PowerShell."
              )
          end
        after
          File.rm_rf(clone_target)
        end
    end
  end

  defp workspace_root_check(settings) do
    root = Path.expand(settings.workspace.root)
    probe = Path.join(root, ".symphony-preflight-#{System.unique_integer([:positive])}")

    try do
      with :ok <- File.mkdir_p(root),
           :ok <- File.write(probe, "ok"),
           {:ok, "ok"} <- File.read(probe) do
        pass(
          "Workspace root",
          "#{root} is writable. Trust this root in Codex if project-local .codex config is expected."
        )
      else
        {:error, reason} ->
          fail(
            "Workspace root",
            "#{root} is not writable: #{inspect(reason)}",
            "Choose a writable workspace.root that is separate from your normal checkout."
          )
      end
    after
      File.rm(probe)
    end
  end

  defp dashboard_port_check(settings, deps) do
    case settings.server.port do
      nil ->
        skip("Dashboard port", "No dashboard port is configured.")

      port ->
        port_available? = Map.get(deps, :port_available?, &port_available?/1)

        if port_available?.(port) do
          pass("Dashboard port", "Port #{port} is available.")
        else
          fail(
            "Dashboard port",
            "Port #{port} is already in use.",
            "Stop the process using the port or choose another `server.port` / `--port` value."
          )
        end
    end
  end

  defp powershell_hooks_check(settings, deps) do
    if hooks_configured?(settings.hooks) do
      local_shell_run = Map.get(deps, :local_shell_run, &LocalShell.run/2)

      case local_shell_run.(powershell_hook_probe(settings.hooks), cd: File.cwd!()) do
        {:ok, {version, 0}} ->
          pass("PowerShell hooks", "PowerShell can parse configured hooks. Version: #{String.trim(version)}.")

        {:ok, {output, status}} ->
          fail(
            "PowerShell hooks",
            "PowerShell hook parse probe exited #{status}: #{sanitize_command_output(output)}",
            "Fix the configured hook script syntax or install PowerShell 5.1+ / PowerShell 7 for non-interactive execution."
          )

        {:error, reason} ->
          fail(
            "PowerShell hooks",
            "Could not start PowerShell for hooks: #{inspect(reason)}",
            "Install PowerShell and ensure pwsh.exe or powershell.exe is on PATH."
          )
      end
    else
      skip("PowerShell hooks", "No workspace hooks are configured.")
    end
  end

  defp configured_clone_url(nil), do: nil

  defp configured_clone_url(command) when is_binary(command) do
    case Regex.run(~r/\bgit\s+clone(?:\s+\S+)*\s+['"]?((?:https?:\/\/|ssh:\/\/|git@)[^\s'"]+)/, command) do
      [_match, url] -> String.trim(url, "'\"")
      _ -> nil
    end
  end

  defp sanitize_command_output(output) when is_binary(output) do
    output
    |> String.trim()
    |> then(&Regex.replace(~r/[a-z][a-z0-9+.-]*:\/\/[^\s'"]+/i, &1, fn url -> redact_url(url) end))
  end

  defp redact_url(url) when is_binary(url) do
    Regex.replace(~r/^([a-z][a-z0-9+.-]*:\/\/)[^\/\s@]+@/i, url, "\\1[redacted]@")
  end

  defp hooks_configured?(hooks) do
    Enum.any?([hooks.after_create, hooks.before_run, hooks.after_run, hooks.before_remove], &is_binary/1)
  end

  defp preflight_workspace(root) do
    root
    |> Path.expand()
    |> Path.join(".symphony-preflight-codex-#{System.unique_integer([:positive])}")
  end

  defp preflight_clone_target(root) do
    root
    |> Path.expand()
    |> Path.join(".symphony-preflight-clone-#{System.unique_integer([:positive])}")
  end

  defp port_available?(port) when is_integer(port) and port >= 0 do
    case :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, false}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp powershell_hook_probe(hooks) do
    hooks
    |> configured_hooks()
    |> Enum.map_join("\n", fn {name, command} ->
      """
      [scriptblock]::Create(@'
      #{command}
      '@) | Out-Null
      Write-Output "hook #{name} parsed"
      """
    end)
    |> then(fn hook_checks ->
      """
      $ErrorActionPreference = "Stop"
      #{hook_checks}
      $PSVersionTable.PSVersion.ToString()
      """
    end)
  end

  defp configured_hooks(hooks) do
    [
      {"after_create", hooks.after_create},
      {"before_run", hooks.before_run},
      {"after_run", hooks.after_run},
      {"before_remove", hooks.before_remove}
    ]
    |> Enum.filter(fn {_name, command} -> is_binary(command) end)
  end

  defp pass(name, message), do: %Check{name: name, status: :pass, message: message}
  defp skip(name, message), do: %Check{name: name, status: :skip, message: message}
  defp warn(name, message, remediation), do: %Check{name: name, status: :warn, message: message, remediation: remediation}

  defp fail(name, message, remediation) do
    %Check{name: name, status: :fail, message: message, remediation: remediation}
  end

  defp status_label(:pass), do: "PASS"
  defp status_label(:fail), do: "FAIL"
  defp status_label(:skip), do: "SKIP"
  defp status_label(:warn), do: "WARN"
end
