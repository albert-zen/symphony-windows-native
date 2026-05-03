defmodule SymphonyElixirWeb.WorkflowConfigProjection do
  @moduledoc """
  Read-only, redacted projection of the active WORKFLOW.md configuration.
  """

  alias SymphonyElixir.{Config, Redactor, Workflow}

  @hash_bytes 12
  @prompt_preview_chars 240

  @type projection :: %{
          status: :ok | :error,
          workflow: map(),
          config: map() | nil,
          prompt: map() | nil,
          error: term() | nil
        }

  @spec current() :: projection()
  def current do
    path = Workflow.workflow_file_path()
    workflow = workflow_file_projection(path)

    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        case Config.settings() do
          {:ok, settings} ->
            %{
              status: :ok,
              workflow: workflow,
              config: config_projection(settings),
              prompt: prompt_projection(prompt),
              error: nil
            }

          {:error, reason} ->
            error_projection(workflow, reason)
        end

      {:error, reason} ->
        error_projection(workflow, reason)
    end
  end

  defp error_projection(workflow, reason) do
    %{status: :error, workflow: workflow, config: nil, prompt: nil, error: inspect(reason)}
  end

  defp workflow_file_projection(path) do
    case File.read(path) do
      {:ok, content} ->
        stat = file_stat(path)

        %{
          path: path,
          exists?: true,
          bytes: byte_size(content),
          hash: content_hash(content),
          modified_at: modified_at(stat)
        }

      {:error, reason} ->
        %{
          path: path,
          exists?: false,
          bytes: nil,
          hash: nil,
          modified_at: nil,
          error: inspect(reason)
        }
    end
  end

  defp file_stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> stat
      _ -> nil
    end
  end

  defp modified_at(%File.Stat{mtime: mtime}) when is_integer(mtime) do
    mtime
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp modified_at(_stat), do: nil

  defp content_hash(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_bytes)
  end

  defp config_projection(settings) do
    %{
      tracker: %{
        kind: settings.tracker.kind,
        endpoint: settings.tracker.endpoint,
        project_slug: settings.tracker.project_slug,
        api_key: configured_state(settings.tracker.api_key),
        assignee: configured_state(settings.tracker.assignee),
        labels: settings.tracker.labels,
        dispatch_states: settings.tracker.dispatch_states,
        active_states: settings.tracker.active_states,
        terminal_states: settings.tracker.terminal_states
      },
      concurrency: %{
        max_agents: settings.agent.max_concurrent_agents,
        per_host: settings.worker.max_concurrent_agents_per_host,
        by_state: settings.agent.max_concurrent_agents_by_state,
        max_turns: settings.agent.max_turns,
        max_retry_backoff_ms: settings.agent.max_retry_backoff_ms
      },
      codex: %{
        command: settings.codex.command,
        approval_policy: Redactor.redact(settings.codex.approval_policy),
        thread_sandbox: settings.codex.thread_sandbox,
        turn_sandbox_policy: Redactor.redact(settings.codex.turn_sandbox_policy),
        turn_timeout_ms: settings.codex.turn_timeout_ms,
        read_timeout_ms: settings.codex.read_timeout_ms,
        stall_timeout_ms: settings.codex.stall_timeout_ms,
        command_watchdog_long_running_ms: settings.codex.command_watchdog_long_running_ms,
        command_watchdog_idle_ms: settings.codex.command_watchdog_idle_ms,
        command_watchdog_stalled_ms: settings.codex.command_watchdog_stalled_ms,
        command_watchdog_repeated_output_limit: settings.codex.command_watchdog_repeated_output_limit,
        command_watchdog_block_on_stall: settings.codex.command_watchdog_block_on_stall,
        review_readiness_repository: settings.codex.review_readiness_repository,
        review_readiness_required_checks: settings.codex.review_readiness_required_checks
      },
      workspace: %{
        root: settings.workspace.root,
        startup_cleanup_ttl_ms: settings.workspace.startup_cleanup_ttl_ms
      },
      worker: %{
        ssh_hosts: settings.worker.ssh_hosts,
        max_concurrent_agents_per_host: settings.worker.max_concurrent_agents_per_host
      },
      hooks: %{
        after_create: configured_state(settings.hooks.after_create),
        before_run: configured_state(settings.hooks.before_run),
        after_run: configured_state(settings.hooks.after_run),
        before_remove: configured_state(settings.hooks.before_remove),
        timeout_ms: settings.hooks.timeout_ms
      },
      observability: %{
        dashboard_enabled: settings.observability.dashboard_enabled,
        refresh_ms: settings.observability.refresh_ms,
        render_interval_ms: settings.observability.render_interval_ms,
        steer_token: configured_state(settings.observability.steer_token)
      },
      server: %{
        host: settings.server.host,
        port: settings.server.port
      },
      polling: %{
        interval_ms: settings.polling.interval_ms
      }
    }
  end

  defp configured_state(value) when is_binary(value) and value != "", do: "configured"
  defp configured_state(_value), do: "missing"

  defp prompt_projection(prompt) when is_binary(prompt) do
    redacted = Redactor.redact(prompt)

    %{
      bytes: byte_size(prompt),
      lines: prompt |> String.split("\n") |> length(),
      preview: preview(redacted),
      body: redacted
    }
  end

  defp preview(prompt) do
    trimmed = String.trim(prompt)

    if String.length(trimmed) > @prompt_preview_chars do
      String.slice(trimmed, 0, @prompt_preview_chars) <> "..."
    else
      trimmed
    end
  end
end
