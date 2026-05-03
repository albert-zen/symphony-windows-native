defmodule SymphonyElixirWeb.ConfigLive do
  @moduledoc """
  Operator editor for the active workflow configuration.
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
     |> assign(:workflow_content, workflow_content())
     |> assign(:workflow_path_input, projection.workflow.path)
     |> assign(:workflow_candidates, WorkflowConfigEditor.workflow_candidates())
     |> assign(:preview, nil)
     |> assign(:active_workers_count, active_workers_count())}
  end

  @impl true
  def handle_event("preview_config", %{"workflow" => %{"content" => content}}, socket) do
    case WorkflowConfigEditor.preview_content(content) do
      {:ok, preview} ->
        {:noreply,
         socket
         |> assign(:workflow_content, content)
         |> assign(:preview, Map.put(preview, :content, content))
         |> put_flash(:info, "Preview ready. Review the diff before applying.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:workflow_content, content)
         |> assign(:preview, nil)
         |> put_flash(:error, editor_error_message(reason))}
    end
  end

  def handle_event("apply_config", _params, %{assigns: %{preview: %{content: content}}} = socket) do
    active_workers_count = active_workers_count()

    case apply_content_preview(content, active_workers_count) do
      {:ok, applied} ->
        projection = WorkflowConfigProjection.current()

        {:noreply,
         socket
         |> assign(:projection, projection)
         |> assign(:workflow_content, workflow_content())
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

  def handle_event("select_workflow", %{"workflow_path" => %{"path" => path}}, socket) do
    active_workers_count = active_workers_count()

    case WorkflowConfigEditor.switch_workflow_path(path, active_workers_count: active_workers_count) do
      {:ok, selected} ->
        projection = WorkflowConfigProjection.current()

        {:noreply,
         socket
         |> assign(:projection, projection)
         |> assign(:workflow_content, workflow_content())
         |> assign(:workflow_path_input, projection.workflow.path)
         |> assign(:workflow_candidates, WorkflowConfigEditor.workflow_candidates())
         |> assign(:preview, nil)
         |> assign(:active_workers_count, active_workers_count())
         |> put_flash(:info, "Workflow switched to #{selected.path}. Managed reload will use this path; manual restarts must pass it explicitly.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:workflow_path_input, path)
         |> assign(:active_workers_count, active_workers_count)
         |> put_flash(:error, editor_error_message(reason))}
    end
  end

  def handle_event("reveal_workflow_file", _params, socket) do
    case reveal_workflow_file(socket.assigns.projection.workflow.path) do
      :ok -> {:noreply, put_flash(socket, :info, "Opened Explorer for the active workflow file.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, editor_error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="page-shell">
      <header class="page-header">
        <a class="page-back" href="/">‹ Dashboard</a>
        <span class="page-brand">Operator Config</span>
        <span class="page-brand-sub">Workflow.md editor</span>
        <span class={config_status_class(@projection.status)}><%= @projection.status %></span>
      </header>

      <%= if @projection.status == :error do %>
        <section class="page-error">
          <h2 class="error-title">Workflow unavailable</h2>
          <p class="error-copy"><%= @projection.error %></p>
        </section>
      <% end %>

      <section class="page-main page-main-full">
          <%= if @projection.config do %>
            <section class="panel-shell config-editor-panel">
              <div class="section-header config-editor-header">
                <div>
                  <h2 class="page-section-title">Workflow.md</h2>
                  <p class="section-copy detail-path"><%= @projection.workflow.path %></p>
                </div>
                <.form for={%{}} as={:workflow_path} id="workflow-path-picker" phx-submit="select_workflow" class="workflow-path-picker">
                  <label>
                    <span>Workflow file</span>
                    <input name="workflow_path[path]" list="workflow-candidates" value={@workflow_path_input} placeholder="Choose or enter a .md path" />
                  </label>
                  <datalist id="workflow-candidates">
                    <%= for path <- @workflow_candidates do %>
                      <option value={path}></option>
                    <% end %>
                  </datalist>
                  <button type="submit" class="secondary">Use file</button>
                  <button type="button" class="secondary" phx-click="reveal_workflow_file">Reveal in Explorer</button>
                </.form>
                <span class={active_workers_badge_class(@active_workers_count)}>
                  <%= active_workers_label(@active_workers_count) %>
                </span>
              </div>

              <dl class="config-meta-strip">
                <div><dt>Status</dt><dd><%= if @projection.workflow.exists?, do: "present", else: "missing" %></dd></div>
                <div><dt>Hash</dt><dd class="mono"><%= @projection.workflow.hash || "n/a" %></dd></div>
                <div><dt>Bytes</dt><dd class="numeric"><%= format_value(@projection.workflow.bytes) %></dd></div>
                <div><dt>Modified</dt><dd class="mono"><%= @projection.workflow.modified_at || "n/a" %></dd></div>
                <div :if={@projection.prompt}><dt>Prompt</dt><dd><%= @projection.prompt.lines %> lines · <%= @projection.prompt.bytes %> bytes</dd></div>
              </dl>

              <.form for={%{}} as={:workflow} id="workflow-config-editor" phx-submit="preview_config" class="config-edit-form">
                <textarea class="workflow-file-editor mono" name="workflow[content]" rows="32"><%= @workflow_content %></textarea>

                <div class="config-actions">
                  <button type="submit">Preview diff</button>
                  <button type="button" class="secondary" phx-click="apply_config" disabled={is_nil(@preview)}>Apply</button>
                </div>
              </.form>

              <section class="config-apply-note">
                <h3 class="page-section-title">Apply behavior</h3>
                <ul>
                  <li>Apply validates the whole file, writes a backup, updates WORKFLOW.md, and reloads WorkflowStore immediately.</li>
                  <li>Changes affect future polls and future worker runs; active workers are blocked from mid-run config changes.</li>
                  <li>Server listener and operator auth changes may still require a runtime restart; preview the diff to see exact notes.</li>
                </ul>
              </section>

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
                  <section class="config-apply-note">
                    <h4 class="page-section-title">Application notes</h4>
                    <p><%= @preview.application_effects.workflow_store %></p>
                    <p><%= @preview.application_effects.future_work %></p>
                    <p><%= @preview.application_effects.active_workers %></p>
                    <%= if @preview.application_effects.restart_required? do %>
                      <p class="config-warning">Runtime restart recommended after Apply.</p>
                      <ul>
                        <%= for reason <- @preview.application_effects.restart_reasons do %>
                          <li><%= reason %></li>
                        <% end %>
                      </ul>
                    <% else %>
                      <p>No runtime restart is expected for the proposed diff.</p>
                    <% end %>
                  </section>
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

  defp active_workers_count do
    case Presenter.state_payload(orchestrator(), snapshot_timeout_ms()) do
      %{running: running} when is_list(running) -> length(running)
      _ -> :unknown
    end
  end

  defp workflow_content do
    case WorkflowConfigEditor.current_content() do
      {:ok, content} -> content
      {:error, reason} -> "Unable to read workflow file: #{inspect(reason)}"
    end
  end

  defp apply_content_preview(_content, :unknown), do: {:error, :active_workers_unknown}
  defp apply_content_preview(content, active_workers_count), do: WorkflowConfigEditor.apply_content(content, active_workers_count: active_workers_count)

  defp reveal_workflow_file(path) do
    case Application.get_env(:symphony_elixir, :workflow_config_reveal_fun) do
      reveal_fun when is_function(reveal_fun, 1) -> reveal_fun.(path)
      _ -> WorkflowConfigEditor.reveal_path(path)
    end
  end

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
  defp editor_error_message(:blank_workflow_path), do: "Workflow path is blank."
  defp editor_error_message(:workflow_path_not_markdown), do: "Workflow path must point to a .md file."
  defp editor_error_message({:missing_workflow_file, path, reason}), do: "Workflow file is unavailable: #{path} (#{reason})."
  defp editor_error_message(:explorer_unavailable), do: "Explorer is unavailable on this machine."
  defp editor_error_message({:unsupported_os, os}), do: "Explorer reveal is only supported on Windows; current OS is #{inspect(os)}."
  defp editor_error_message({:explorer_failed, status, output}), do: "Explorer failed with status #{status}: #{output}."
  defp editor_error_message({:backup_failed, reason}), do: "Workflow backup failed: #{inspect(reason)}."
  defp editor_error_message({:write_failed, reason}), do: "Workflow write failed: #{inspect(reason)}."
  defp editor_error_message(reason), do: "Workflow edit failed: #{inspect(reason)}."
end
