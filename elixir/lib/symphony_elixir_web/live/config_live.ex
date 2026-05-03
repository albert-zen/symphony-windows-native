defmodule SymphonyElixirWeb.ConfigLive do
  @moduledoc """
  Read-only operator view of the active workflow configuration.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.WorkflowConfigEditor
  alias SymphonyElixirWeb.{Endpoint, Presenter, WorkflowConfigProjection}

  @impl true
  def mount(_params, _session, socket) do
    projection = WorkflowConfigProjection.current()

    {:ok,
     socket
     |> assign(:projection, projection)
     |> assign(:form_values, form_values(projection))
     |> assign(:preview, nil)
     |> assign(:active_workers_count, active_workers_count())}
  end

  @impl true
  def handle_event("preview_config", %{"workflow" => params}, socket) do
    case WorkflowConfigEditor.preview(params) do
      {:ok, preview} ->
        {:noreply,
         socket
         |> assign(:form_values, params)
         |> assign(:preview, Map.put(preview, :params, params))
         |> put_flash(:info, "Preview ready. Review the diff before applying.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form_values, params)
         |> assign(:preview, nil)
         |> put_flash(:error, editor_error_message(reason))}
    end
  end

  def handle_event("apply_config", _params, %{assigns: %{preview: %{params: params}}} = socket) do
    active_workers_count = active_workers_count()

    case apply_preview(params, active_workers_count) do
      {:ok, applied} ->
        projection = WorkflowConfigProjection.current()

        {:noreply,
         socket
         |> assign(:projection, projection)
         |> assign(:form_values, form_values(projection))
         |> assign(:preview, nil)
         |> assign(:active_workers_count, active_workers_count())
         |> put_flash(:info, "Workflow applied. New hash #{applied.applied_hash}; backup written.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:active_workers_count, active_workers_count)
         |> put_flash(:error, editor_error_message(reason))}
    end
  end

  def handle_event("apply_config", _params, socket) do
    {:noreply, put_flash(socket, :error, "Preview the workflow diff before applying.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="page-shell">
      <header class="page-header">
        <a class="page-back" href="/">‹ Dashboard</a>
        <span class="page-brand">Operator Config</span>
        <span class="page-brand-sub">Safe workflow controls</span>
        <span class={config_status_class(@projection.status)}><%= @projection.status %></span>
      </header>

      <%= if @projection.status == :error do %>
        <section class="page-error">
          <h2 class="error-title">Workflow unavailable</h2>
          <p class="error-copy"><%= @projection.error %></p>
        </section>
      <% end %>

      <div class="page-grid">
        <aside class="page-sidebar">
          <section class="page-sidebar-section">
            <h3 class="page-section-title">Workflow file</h3>
            <dl class="page-kv">
              <div><dt>Path</dt><dd class="detail-path"><%= @projection.workflow.path %></dd></div>
              <div><dt>Status</dt><dd><%= if @projection.workflow.exists?, do: "present", else: "missing" %></dd></div>
              <div><dt>Hash</dt><dd class="mono"><%= @projection.workflow.hash || "n/a" %></dd></div>
              <div><dt>Bytes</dt><dd class="numeric"><%= format_value(@projection.workflow.bytes) %></dd></div>
              <div><dt>Modified</dt><dd class="mono"><%= @projection.workflow.modified_at || "n/a" %></dd></div>
            </dl>
          </section>

          <section :if={@projection.prompt} class="page-sidebar-section">
            <h3 class="page-section-title">Prompt</h3>
            <dl class="page-kv">
              <div><dt>Lines</dt><dd class="numeric"><%= @projection.prompt.lines %></dd></div>
              <div><dt>Bytes</dt><dd class="numeric"><%= @projection.prompt.bytes %></dd></div>
            </dl>
            <p class="config-preview"><%= @projection.prompt.preview %></p>
          </section>
        </aside>

        <section class="page-main">
          <%= if @projection.config do %>
            <section class="panel-shell config-editor-panel">
              <div class="section-header">
                <div>
                  <h2 class="page-section-title">Safe edits</h2>
                  <p class="section-copy">
                    Low-risk runtime knobs only. Prompt, secrets, worker hosts, hooks, and repository identity stay read-only here.
                  </p>
                </div>
                <span class={active_workers_badge_class(@active_workers_count)}>
                  <%= active_workers_label(@active_workers_count) %>
                </span>
              </div>

              <.form for={%{}} as={:workflow} id="workflow-config-editor" phx-submit="preview_config" class="config-edit-form">
                <fieldset class="config-fieldset">
                  <legend>Scheduling</legend>
                  <label>
                    <span>Max agents</span>
                    <input type="number" min="1" name="workflow[agent.max_concurrent_agents]" value={@form_values["agent.max_concurrent_agents"]} />
                  </label>
                  <label>
                    <span>Poll interval ms</span>
                    <input type="number" min="1" name="workflow[polling.interval_ms]" value={@form_values["polling.interval_ms"]} />
                  </label>
                  <label>
                    <span>Max turns</span>
                    <input type="number" min="1" name="workflow[agent.max_turns]" value={@form_values["agent.max_turns"]} />
                  </label>
                  <label class="config-field-wide">
                    <span>Dispatch states</span>
                    <textarea name="workflow[tracker.dispatch_states]" rows="3"><%= @form_values["tracker.dispatch_states"] %></textarea>
                  </label>
                </fieldset>

                <fieldset class="config-fieldset">
                  <legend>Codex timeouts</legend>
                  <label>
                    <span>Turn timeout ms</span>
                    <input type="number" min="1" name="workflow[codex.turn_timeout_ms]" value={@form_values["codex.turn_timeout_ms"]} />
                  </label>
                  <label>
                    <span>Read timeout ms</span>
                    <input type="number" min="1" name="workflow[codex.read_timeout_ms]" value={@form_values["codex.read_timeout_ms"]} />
                  </label>
                  <label>
                    <span>Stall timeout ms</span>
                    <input type="number" min="0" name="workflow[codex.stall_timeout_ms]" value={@form_values["codex.stall_timeout_ms"]} />
                  </label>
                  <label>
                    <span>Long-running ms</span>
                    <input type="number" min="0" name="workflow[codex.command_watchdog_long_running_ms]" value={@form_values["codex.command_watchdog_long_running_ms"]} />
                  </label>
                  <label>
                    <span>Idle watchdog ms</span>
                    <input type="number" min="0" name="workflow[codex.command_watchdog_idle_ms]" value={@form_values["codex.command_watchdog_idle_ms"]} />
                  </label>
                  <label>
                    <span>Stalled watchdog ms</span>
                    <input type="number" min="0" name="workflow[codex.command_watchdog_stalled_ms]" value={@form_values["codex.command_watchdog_stalled_ms"]} />
                  </label>
                  <label>
                    <span>Repeated output limit</span>
                    <input type="number" min="1" name="workflow[codex.command_watchdog_repeated_output_limit]" value={@form_values["codex.command_watchdog_repeated_output_limit"]} />
                  </label>
                </fieldset>

                <fieldset class="config-fieldset">
                  <legend>Observability</legend>
                  <label>
                    <span>Refresh ms</span>
                    <input type="number" min="1" name="workflow[observability.refresh_ms]" value={@form_values["observability.refresh_ms"]} />
                  </label>
                  <label>
                    <span>Render interval ms</span>
                    <input type="number" min="1" name="workflow[observability.render_interval_ms]" value={@form_values["observability.render_interval_ms"]} />
                  </label>
                </fieldset>

                <div class="config-actions">
                  <button type="submit">Preview diff</button>
                  <button type="button" class="secondary" phx-click="apply_config" disabled={is_nil(@preview)}>Apply</button>
                </div>
              </.form>

              <%= if @preview do %>
                <section class="config-diff-preview">
                  <div class="section-header">
                    <div>
                      <h3 class="page-section-title">Diff preview</h3>
                      <p class="section-copy">
                        <%= length(@preview.changed_fields) %> field(s) changed · proposed hash <span class="mono"><%= @preview.proposed_hash %></span>
                      </p>
                    </div>
                  </div>
                  <%= for warning <- @preview.warnings do %>
                    <p class="config-warning"><%= warning %></p>
                  <% end %>
                  <pre class="code-panel"><%= if @preview.diff == "", do: "No changes.", else: @preview.diff %></pre>
                </section>
              <% end %>
            </section>

            <section class="panel-shell">
              <h2 class="page-section-title">Tracker</h2>
              <dl class="page-kv page-kv-wide">
                <div><dt>Kind</dt><dd><%= @projection.config.tracker.kind %></dd></div>
                <div><dt>Endpoint</dt><dd class="detail-path"><%= @projection.config.tracker.endpoint %></dd></div>
                <div><dt>Project</dt><dd><%= @projection.config.tracker.project_slug || "n/a" %></dd></div>
                <div><dt>API key</dt><dd><%= @projection.config.tracker.api_key %></dd></div>
                <div><dt>Assignee</dt><dd><%= @projection.config.tracker.assignee %></dd></div>
                <div><dt>Labels</dt><dd><%= list_label(@projection.config.tracker.labels) %></dd></div>
                <div><dt>Dispatch</dt><dd><%= list_label(@projection.config.tracker.dispatch_states) %></dd></div>
                <div><dt>Active</dt><dd><%= list_label(@projection.config.tracker.active_states) %></dd></div>
                <div><dt>Terminal</dt><dd><%= list_label(@projection.config.tracker.terminal_states) %></dd></div>
              </dl>
            </section>

            <section class="panel-shell">
              <h2 class="page-section-title">Concurrency</h2>
              <dl class="page-kv page-kv-wide">
                <div><dt>Global</dt><dd class="numeric"><%= @projection.config.concurrency.max_agents %></dd></div>
                <div><dt>Per host</dt><dd class="numeric"><%= format_value(@projection.config.concurrency.per_host) %></dd></div>
                <div><dt>Max turns</dt><dd class="numeric"><%= @projection.config.concurrency.max_turns %></dd></div>
                <div><dt>Retry backoff</dt><dd><%= duration_label(@projection.config.concurrency.max_retry_backoff_ms) %></dd></div>
                <div><dt>By state</dt><dd><pre class="config-inline-code"><%= inspect(@projection.config.concurrency.by_state, pretty: true) %></pre></dd></div>
              </dl>
            </section>

            <section class="panel-shell">
              <h2 class="page-section-title">Codex Runtime</h2>
              <dl class="page-kv page-kv-wide">
                <div><dt>Command</dt><dd class="mono"><%= @projection.config.codex.command %></dd></div>
                <div><dt>Sandbox</dt><dd><%= @projection.config.codex.thread_sandbox %></dd></div>
                <div><dt>Turn timeout</dt><dd><%= duration_label(@projection.config.codex.turn_timeout_ms) %></dd></div>
                <div><dt>Read timeout</dt><dd><%= duration_label(@projection.config.codex.read_timeout_ms) %></dd></div>
                <div><dt>Stall timeout</dt><dd><%= duration_label(@projection.config.codex.stall_timeout_ms) %></dd></div>
                <div><dt>Watchdog</dt><dd><%= watchdog_summary(@projection.config.codex) %></dd></div>
                <div><dt>Review repo</dt><dd><%= @projection.config.codex.review_readiness_repository || "n/a" %></dd></div>
                <div><dt>Checks</dt><dd><%= list_label(@projection.config.codex.review_readiness_required_checks) %></dd></div>
              </dl>
            </section>

            <section class="panel-shell">
              <h2 class="page-section-title">Runtime Paths</h2>
              <dl class="page-kv page-kv-wide">
                <div><dt>Workspace</dt><dd class="detail-path"><%= @projection.config.workspace.root %></dd></div>
                <div><dt>Cleanup TTL</dt><dd><%= duration_label(@projection.config.workspace.startup_cleanup_ttl_ms) %></dd></div>
                <div><dt>Workers</dt><dd><%= list_label(@projection.config.worker.ssh_hosts) %></dd></div>
                <div><dt>Server</dt><dd><%= @projection.config.server.host %>:<%= format_value(@projection.config.server.port) %></dd></div>
                <div><dt>Polling</dt><dd><%= duration_label(@projection.config.polling.interval_ms) %></dd></div>
                <div><dt>Dashboard</dt><dd><%= observability_summary(@projection.config.observability) %></dd></div>
              </dl>
            </section>

            <details :if={@projection.prompt} id="config-prompt" class="system-debug" phx-hook="PreserveDetails">
              <summary>Prompt body</summary>
              <pre class="code-panel"><%= @projection.prompt.body %></pre>
            </details>
          <% end %>
        </section>
      </div>
    </section>
    """
  end

  defp config_status_class(:ok), do: "state-badge state-badge-active"
  defp config_status_class(:error), do: "state-badge state-badge-danger"

  defp list_label([]), do: "none"
  defp list_label(value) when is_list(value), do: Enum.join(value, ", ")
  defp list_label(value), do: format_value(value)

  defp format_value(nil), do: "n/a"
  defp format_value(value), do: to_string(value)

  defp duration_label(ms) when is_integer(ms) and ms >= 60_000, do: "#{div(ms, 60_000)}m #{rem(ms, 60_000) |> div(1_000)}s"
  defp duration_label(ms) when is_integer(ms), do: "#{ms}ms"
  defp duration_label(_ms), do: "n/a"

  defp watchdog_summary(codex) do
    "long #{duration_label(codex.command_watchdog_long_running_ms)} · idle #{duration_label(codex.command_watchdog_idle_ms)} · stalled #{duration_label(codex.command_watchdog_stalled_ms)}"
  end

  defp observability_summary(observability) do
    "refresh #{duration_label(observability.refresh_ms)} · render #{duration_label(observability.render_interval_ms)} · steer token #{observability.steer_token}"
  end

  defp form_values(%{status: :ok, config: config}) do
    %{
      "agent.max_concurrent_agents" => config.concurrency.max_agents,
      "polling.interval_ms" => config.polling.interval_ms,
      "agent.max_turns" => config.concurrency.max_turns,
      "tracker.dispatch_states" => Enum.join(config.tracker.dispatch_states, "\n"),
      "codex.turn_timeout_ms" => config.codex.turn_timeout_ms,
      "codex.read_timeout_ms" => config.codex.read_timeout_ms,
      "codex.stall_timeout_ms" => config.codex.stall_timeout_ms,
      "codex.command_watchdog_long_running_ms" => config.codex.command_watchdog_long_running_ms,
      "codex.command_watchdog_idle_ms" => config.codex.command_watchdog_idle_ms,
      "codex.command_watchdog_stalled_ms" => config.codex.command_watchdog_stalled_ms,
      "codex.command_watchdog_repeated_output_limit" => config.codex.command_watchdog_repeated_output_limit,
      "observability.refresh_ms" => config.observability.refresh_ms,
      "observability.render_interval_ms" => config.observability.render_interval_ms
    }
  end

  defp form_values(_projection), do: %{}

  defp active_workers_count do
    case Presenter.state_payload(orchestrator(), snapshot_timeout_ms()) do
      %{running: running} when is_list(running) -> length(running)
      _ -> :unknown
    end
  end

  defp apply_preview(_params, :unknown), do: {:error, :active_workers_unknown}
  defp apply_preview(params, active_workers_count), do: WorkflowConfigEditor.apply(params, active_workers_count: active_workers_count)

  defp active_workers_badge_class(0), do: "state-badge"
  defp active_workers_badge_class(_count), do: "state-badge state-badge-warning"

  defp active_workers_label(:unknown), do: "active workers unknown"
  defp active_workers_label(count), do: "#{count} active workers"

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp editor_error_message({:unsupported_fields, fields}), do: "Unsupported workflow field(s): #{Enum.join(fields, ", ")}."

  defp editor_error_message({:invalid_field, field, message}), do: "#{field} #{message}."
  defp editor_error_message({:active_workers, count}), do: "Workflow edits are blocked while #{count} worker(s) are active."
  defp editor_error_message(:active_workers_unknown), do: "Workflow edits are blocked because active workers could not be inspected."
  defp editor_error_message({:invalid_workflow, reason}), do: "Proposed workflow did not validate: #{inspect(reason)}."
  defp editor_error_message({:backup_failed, reason}), do: "Workflow backup failed: #{inspect(reason)}."
  defp editor_error_message({:write_failed, reason}), do: "Workflow write failed: #{inspect(reason)}."
  defp editor_error_message(reason), do: "Workflow edit failed: #{inspect(reason)}."
end
