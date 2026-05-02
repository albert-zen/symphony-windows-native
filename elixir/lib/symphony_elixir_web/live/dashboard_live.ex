defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:detail_payload, nil)
      |> assign(:detail_error, nil)
      |> assign(:issue_identifier, nil)
      |> assign(:steer_auth_required, steer_auth_required?())
      |> assign(:steer_token_configured, steer_token_configured?())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"issue_identifier" => issue_identifier}, _uri, socket) do
    {:noreply, assign_detail_payload(socket, issue_identifier)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:detail_payload, nil)
     |> assign(:detail_error, nil)
     |> assign(:issue_identifier, nil)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    socket =
      case socket.assigns[:issue_identifier] do
        issue_identifier when is_binary(issue_identifier) -> assign_detail_payload(socket, issue_identifier)
        _ -> socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("steer", %{"steer" => steer_params}, socket) do
    issue_identifier = socket.assigns.issue_identifier
    message = Map.get(steer_params, "message", "")
    session_id = Map.get(steer_params, "session_id")
    operator_token = Map.get(steer_params, "operator_token")

    case authorize_steer(operator_token) do
      :ok ->
        submit_steer(socket, issue_identifier, message, session_id)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, steer_error_message(reason))}
    end
  end

  defp submit_steer(socket, issue_identifier, message, session_id) do
    if non_blank_binary?(session_id) do
      case Presenter.steer_payload(issue_identifier, message, session_id, orchestrator()) do
        {:ok, _payload} ->
          {:noreply,
           socket
           |> put_flash(:info, "Steer message queued for #{issue_identifier}.")
           |> assign_detail_payload(issue_identifier)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, steer_error_message(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, steer_error_message(:session_mismatch))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @live_action == :worker_detail do %>
      <section class="dashboard-shell">
        <header class="hero-card">
          <div class="hero-grid">
            <div>
              <p class="eyebrow">Worker Detail</p>
              <h1 class="hero-title"><%= @issue_identifier %></h1>
              <p class="hero-copy">Agent conversation view for the active Symphony worker session.</p>
            </div>
            <div class="status-stack">
              <a class="subtle-button" href="/">Dashboard</a>
            </div>
          </div>
        </header>

        <%= if @detail_error do %>
          <section class="error-card">
            <h2 class="error-title">Worker unavailable</h2>
            <p class="error-copy"><%= @detail_error %></p>
          </section>
        <% else %>
          <% detail = @detail_payload %>
          <% running =
            detail.running ||
              %{
                state: detail.status,
                session_id: nil,
                turn_count: 0,
                tokens: %{input_tokens: nil, output_tokens: nil, total_tokens: nil}
              } %>

          <section class="metric-grid">
            <article class="metric-card">
              <p class="metric-label">State</p>
              <p class="metric-value"><%= running.state %></p>
              <p class="metric-detail"><%= detail.title || detail.issue_identifier %></p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Session</p>
              <p class="metric-value mono detail-session"><%= running.session_id || "n/a" %></p>
              <p class="metric-detail">Turn <%= running.turn_count %></p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Workspace</p>
              <p class="metric-value detail-path"><%= detail.workspace.path %></p>
              <p class="metric-detail"><%= detail.workspace.host || "local" %></p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Branch / Checks</p>
              <p class="metric-value detail-path"><%= detail.retry && detail.retry.branch_name || "n/a" %></p>
              <p class="metric-detail"><%= if detail.url, do: detail.url, else: "PR and checks unavailable" %></p>
            </article>
          </section>

          <section class="agent-panel">
            <div class="agent-panel-header">
              <div>
                <h2 class="section-title">Conversation</h2>
                <p class="section-copy">
                  <%= if detail.running do %>
                    <%= if @steer_auth_required and not @steer_token_configured do %>
                      Steering is locked because this dashboard is exposed without an operator token.
                    <% else %>
                      Messages and tool activity for this exact worker session.
                    <% end %>
                  <% else %>
                    This worker is not running, so steering is disabled.
                  <% end %>
                </p>
              </div>
              <span class="state-badge"><%= length(detail.conversation) %> items</span>
            </div>

            <div class="conversation-scroll">
              <%= if detail.conversation == [] do %>
                <p class="empty-state">No Codex conversation events recorded yet.</p>
              <% else %>
                <ol class="conversation-list">
                  <li :for={item <- detail.conversation} class={conversation_item_class(item)}>
                    <div class="conversation-meta">
                      <span><%= item.title %></span>
                      <span class="mono"><%= item.at || "pending" %></span>
                    </div>

                    <%= case item.type do %>
                      <% "tool" -> %>
                        <div class="tool-card">
                          <div class="tool-card-main">
                            <span class={tool_status_class(item.status)}><%= item.status %></span>
                            <code><%= item.command %></code>
                            <%= if item.elapsed_ms do %>
                              <span class="muted mono"><%= format_elapsed_ms(item.elapsed_ms) %></span>
                            <% end %>
                          </div>
                          <%= if item.output_excerpt != "" do %>
                            <pre class="tool-output"><%= item.output_excerpt %><%= if item.output_truncated?, do: "\n[truncated]" %></pre>
                          <% end %>
                        </div>
                      <% _ -> %>
                        <p class="message-bubble-text"><%= item.excerpt || "Worker update" %></p>
                    <% end %>

                    <details class="raw-details">
                      <summary>Debug JSON</summary>
                      <div :for={raw <- item.raw || []} class="debug-block">
                        <p class="debug-label"><%= raw.label %><%= if raw.truncated?, do: " (truncated)" %></p>
                        <pre class="code-panel"><%= raw.excerpt %></pre>
                      </div>
                    </details>
                  </li>
                </ol>
              <% end %>
            </div>

            <.form for={%{}} as={:steer} phx-submit="steer" class="composer-form">
              <input type="hidden" name="steer[session_id]" value={running.session_id || ""} />
              <%= if @steer_auth_required and @steer_token_configured do %>
                <input
                  type="password"
                  name="steer[operator_token]"
                  class="steer-token"
                  placeholder="Operator token"
                  autocomplete="off"
                  disabled={is_nil(running.session_id)}
                />
              <% end %>
              <div class="composer-row">
                <textarea
                  name="steer[message]"
                  class="composer-input"
                  rows="2"
                  placeholder="Send a targeted instruction to this running worker"
                  disabled={is_nil(running.session_id) or steer_locked?(@steer_auth_required, @steer_token_configured)}
                ></textarea>
                <button
                  type="submit"
                  disabled={is_nil(running.session_id) or steer_locked?(@steer_auth_required, @steer_token_configured)}
                >Send</button>
              </div>
            </.form>
          </section>

          <details class="debug-drawer">
            <summary>Worker debug payload</summary>
            <pre class="code-panel"><%= detail.debug.payload_excerpt %><%= if detail.debug.payload_truncated?, do: "\n[truncated]" %></pre>
          </details>
        <% end %>
      </section>
    <% else %>
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy"><%= rate_limit_metadata(@payload.rate_limits) %></p>
            </div>
          </div>

          <%= if rate_limit_snapshot?(@payload.rate_limits) do %>
            <div class="rate-limit-list">
              <article :for={limit <- rate_limit_rows(@payload.rate_limits, @now)} class="rate-limit-row">
                <div class="rate-limit-main">
                  <div>
                    <p class="rate-limit-name"><%= limit.label %></p>
                    <p class="rate-limit-detail">
                      <%= limit.window %>
                      <%= if limit.reset do %>
                        · <%= limit.reset %>
                      <% end %>
                    </p>
                  </div>
                  <span class={limit.badge_class}><%= limit.used_label %></span>
                </div>
                <div class="rate-limit-bar" aria-label={limit.progress_label}>
                  <span class={limit.bar_class} style={"width: #{limit.progress_width}%"}></span>
                </div>
                <%= if limit.reset_absolute do %>
                  <p class="rate-limit-absolute">
                    Reset at
                    <time
                      id={limit.reset_id}
                      phx-hook="LocalTime"
                      datetime={limit.reset_absolute.iso}
                    ><%= limit.reset_absolute.fallback %></time>
                  </p>
                <% end %>
              </article>
            </div>

            <details class="raw-details rate-limit-debug">
              <summary>Raw rate-limit payload</summary>
              <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
            </details>
          <% else %>
            <p class="empty-state">No upstream rate-limit snapshot is available yet.</p>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/workers/#{entry.issue_identifier}"}>Worker detail</a>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack numeric">
                        <span><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></span>
                        <%= if entry.command_watchdog do %>
                          <span class={watchdog_badge_class(entry.command_watchdog.classification)}>
                            <%= entry.command_watchdog.classification %>
                            · <%= format_watchdog_age(entry.command_watchdog.age_ms) %>
                          </span>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Kind</th>
                    <th>Branch</th>
                    <th>Due at</th>
                    <th>Error</th>
                    <th>Prior error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td><%= entry.error_kind || "n/a" %></td>
                    <td class="mono"><%= entry.branch_name || "n/a" %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                    <td><%= entry.prior_error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    <% end %>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp assign_detail_payload(socket, issue_identifier) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        socket
        |> assign(:detail_payload, payload)
        |> assign(:detail_error, nil)
        |> assign(:issue_identifier, issue_identifier)

      {:error, :issue_not_found} ->
        socket
        |> assign(:detail_payload, nil)
        |> assign(:detail_error, "No active or retrying worker was found for #{issue_identifier}.")
        |> assign(:issue_identifier, issue_identifier)
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp steer_auth_required?, do: Endpoint.config(:steer_auth_required) == true

  defp steer_token_configured? do
    case Endpoint.config(:steer_token) do
      token when is_binary(token) -> String.trim(token) != ""
      _ -> false
    end
  end

  defp authorize_steer(operator_token) do
    if steer_auth_required?(), do: authorize_exposed_steer(operator_token), else: :ok
  end

  defp authorize_exposed_steer(operator_token) do
    case Endpoint.config(:steer_token) do
      token when is_binary(token) ->
        case String.trim(token) do
          "" -> {:error, :steer_auth_required}
          expected_token -> compare_steer_token(operator_token, expected_token)
        end

      _ ->
        {:error, :steer_auth_required}
    end
  end

  defp compare_steer_token(operator_token, expected_token) do
    submitted_token = String.trim(operator_token || "")

    if byte_size(submitted_token) == byte_size(expected_token) and
         Plug.Crypto.secure_compare(submitted_token, expected_token) do
      :ok
    else
      {:error, :invalid_steer_token}
    end
  end

  defp non_blank_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_blank_binary?(_value), do: false

  defp steer_locked?(true, false), do: true
  defp steer_locked?(_required, _configured), do: false

  defp total_runtime_seconds(payload, now) do
    base_seconds = payload.codex_totals.seconds_running || 0
    active_count = length(payload.running || [])

    base_seconds + active_count * runtime_seconds_since_generated_at(payload.generated_at, now)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp runtime_seconds_since_generated_at(generated_at, %DateTime{} = now) when is_binary(generated_at) do
    case DateTime.from_iso8601(generated_at) do
      {:ok, parsed, _offset} -> max(DateTime.diff(now, parsed, :second), 0)
      _ -> 0
    end
  end

  defp runtime_seconds_since_generated_at(_generated_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp rate_limit_snapshot?(%{} = snapshot), do: map_size(snapshot) > 0
  defp rate_limit_snapshot?(_snapshot), do: false

  defp rate_limit_metadata(%{} = snapshot) when map_size(snapshot) > 0 do
    [
      field_value(snapshot, [
        :limit_id,
        :limitId,
        :limit_name,
        :limitName,
        "limit_id",
        "limitId",
        "limit_name",
        "limitName"
      ]),
      field_value(snapshot, [:plan_type, :planType, "plan_type", "planType"])
    ]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "Latest upstream rate-limit snapshot."
      values -> "Latest upstream rate-limit snapshot for #{Enum.join(values, " · ")}."
    end
  end

  defp rate_limit_metadata(_snapshot), do: "Latest upstream rate-limit snapshot, when available."

  defp rate_limit_rows(snapshot, now) do
    [
      rate_limit_row("Primary", field_value(snapshot, [:primary, "primary"]), now),
      rate_limit_row("Secondary", field_value(snapshot, [:secondary, "secondary"]), now)
    ]
  end

  defp rate_limit_row(label, %{} = bucket, now) do
    used_percent = used_percent(bucket)
    reset_at = reset_at(bucket, now)
    reset_id = "rate-limit-reset-#{String.downcase(label)}"

    %{
      label: label,
      reset_id: reset_id,
      used_label: used_label(used_percent),
      progress_label: "#{label} limit #{used_label(used_percent)}",
      progress_width: used_percent || 0,
      badge_class: rate_limit_badge_class(used_percent),
      bar_class: rate_limit_bar_class(used_percent),
      window: window_label(field_value(bucket, [:window_duration_mins, :windowDurationMins, "window_duration_mins", "windowDurationMins"])),
      reset: reset_relative(reset_at, now),
      reset_absolute: reset_absolute(reset_at)
    }
  end

  defp rate_limit_row(label, _bucket, _now) do
    %{
      label: label,
      reset_id: nil,
      used_label: "n/a",
      progress_label: "#{label} limit unavailable",
      progress_width: 0,
      badge_class: "rate-limit-badge",
      bar_class: "rate-limit-bar-fill",
      window: "window n/a",
      reset: nil,
      reset_absolute: nil
    }
  end

  defp field_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      value = Map.get(map, key)
      if is_nil(value), do: nil, else: value
    end)
  end

  defp field_value(_map, _keys), do: nil

  defp used_percent(bucket) do
    direct = field_value(bucket, [:used_percent, :usedPercent, "used_percent", "usedPercent"])

    cond do
      is_number(direct) ->
        clamp_percent(round(direct))

      is_number(field_value(bucket, [:limit, "limit"])) and is_number(field_value(bucket, [:remaining, "remaining"])) ->
        limit = field_value(bucket, [:limit, "limit"])
        remaining = field_value(bucket, [:remaining, "remaining"])

        if limit > 0 do
          clamp_percent(round((limit - remaining) / limit * 100))
        end

      true ->
        nil
    end
  end

  defp clamp_percent(value), do: value |> max(0) |> min(100)

  defp used_label(value) when is_integer(value), do: "#{value}% used"
  defp used_label(_value), do: "n/a"

  defp rate_limit_badge_class(value) when is_integer(value) and value >= 90,
    do: "rate-limit-badge rate-limit-badge-danger"

  defp rate_limit_badge_class(value) when is_integer(value) and value >= 70,
    do: "rate-limit-badge rate-limit-badge-warning"

  defp rate_limit_badge_class(_value), do: "rate-limit-badge"

  defp rate_limit_bar_class(value) when is_integer(value) and value >= 90,
    do: "rate-limit-bar-fill rate-limit-bar-fill-danger"

  defp rate_limit_bar_class(value) when is_integer(value) and value >= 70,
    do: "rate-limit-bar-fill rate-limit-bar-fill-warning"

  defp rate_limit_bar_class(_value), do: "rate-limit-bar-fill"

  defp window_label(minutes) when is_integer(minutes), do: "#{duration_label(minutes)} window"
  defp window_label(minutes) when is_float(minutes), do: "#{duration_label(round(minutes))} window"
  defp window_label(_minutes), do: "window n/a"

  defp duration_label(minutes) when minutes > 0 and rem(minutes, 1_440) == 0, do: "#{div(minutes, 1_440)}d"
  defp duration_label(minutes) when minutes > 0 and rem(minutes, 60) == 0, do: "#{div(minutes, 60)}h"
  defp duration_label(minutes) when minutes > 0, do: "#{minutes}m"
  defp duration_label(_minutes), do: "n/a"

  defp reset_at(bucket, now) do
    cond do
      is_binary(field_value(bucket, [:reset_at, :resetAt, "reset_at", "resetAt"])) ->
        parse_datetime(field_value(bucket, [:reset_at, :resetAt, "reset_at", "resetAt"]))

      is_binary(field_value(bucket, [:resets_at, :resetsAt, "resets_at", "resetsAt"])) ->
        parse_datetime(field_value(bucket, [:resets_at, :resetsAt, "resets_at", "resetsAt"]))

      is_number(field_value(bucket, [:resets_at, :resetsAt, "resets_at", "resetsAt"])) ->
        parse_unix_timestamp(field_value(bucket, [:resets_at, :resetsAt, "resets_at", "resetsAt"]))

      is_number(field_value(bucket, [:reset_in_seconds, :resetInSeconds, "reset_in_seconds", "resetInSeconds"])) ->
        DateTime.add(now, trunc(field_value(bucket, [:reset_in_seconds, :resetInSeconds, "reset_in_seconds", "resetInSeconds"])), :second)

      is_number(field_value(bucket, [:resets_in_seconds, :resetsInSeconds, "resets_in_seconds", "resetsInSeconds"])) ->
        DateTime.add(now, trunc(field_value(bucket, [:resets_in_seconds, :resetsInSeconds, "resets_in_seconds", "resetsInSeconds"])), :second)

      is_number(field_value(bucket, [:reset_timestamp, :resetTimestamp, "reset_timestamp", "resetTimestamp"])) ->
        parse_unix_timestamp(field_value(bucket, [:reset_timestamp, :resetTimestamp, "reset_timestamp", "resetTimestamp"]))

      true ->
        nil
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_unix_timestamp(value) do
    unit = if value > 10_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(trunc(value), unit) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  defp reset_relative(%DateTime{} = reset_at, %DateTime{} = now) do
    diff = DateTime.diff(reset_at, now, :second)

    cond do
      diff > 0 -> "resets in #{relative_duration(diff)}"
      diff == 0 -> "resets now"
      true -> "reset #{relative_duration(abs(diff))} ago"
    end
  end

  defp reset_relative(_reset_at, _now), do: nil

  defp relative_duration(seconds) when seconds >= 86_400, do: "#{div(seconds, 86_400)}d"
  defp relative_duration(seconds) when seconds >= 3_600, do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
  defp relative_duration(seconds) when seconds >= 60, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp relative_duration(seconds), do: "#{seconds}s"

  defp reset_absolute(%DateTime{} = reset_at) do
    %{
      iso: DateTime.to_iso8601(reset_at),
      fallback: Calendar.strftime(reset_at, "%Y-%m-%d %H:%M:%S UTC")
    }
  end

  defp reset_absolute(_reset_at), do: nil

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp steer_error_message(:blank_message), do: "Steer message cannot be blank."
  defp steer_error_message(:worker_not_running), do: "Worker is no longer running."
  defp steer_error_message(:session_mismatch), do: "Worker session changed before the steer was sent."
  defp steer_error_message(:steer_auth_required), do: "Operator token is required before steering exposed workers."
  defp steer_error_message(:invalid_steer_token), do: "Operator token is invalid."
  defp steer_error_message(reason), do: "Steer failed: #{inspect(reason)}"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp watchdog_badge_class(classification) do
    base = "state-badge"

    case to_string(classification) do
      "healthy" -> "#{base} state-badge-active"
      "idle" -> "#{base} state-badge-warning"
      "stalled" -> "#{base} state-badge-danger"
      "needs_attention" -> "#{base} state-badge-warning"
      _ -> base
    end
  end

  defp format_watchdog_age(age_ms) when is_integer(age_ms) do
    age_ms
    |> div(1_000)
    |> format_runtime_seconds()
  end

  defp format_watchdog_age(_age_ms), do: "n/a"

  defp format_elapsed_ms(elapsed_ms) when is_integer(elapsed_ms) do
    "#{Float.round(elapsed_ms / 1_000, 1)}s"
  end

  defp format_elapsed_ms(_elapsed_ms), do: "n/a"

  defp conversation_item_class(%{type: "assistant"}), do: "conversation-item conversation-item-assistant"
  defp conversation_item_class(%{type: "user"}), do: "conversation-item conversation-item-user"
  defp conversation_item_class(%{type: "tool"}), do: "conversation-item conversation-item-tool"
  defp conversation_item_class(%{type: "warning"}), do: "conversation-item conversation-item-warning"
  defp conversation_item_class(_item), do: "conversation-item conversation-item-system"

  defp tool_status_class(status) do
    base = "tool-status"

    cond do
      status == "running" -> "#{base} tool-status-running"
      String.starts_with?(to_string(status), "failed") -> "#{base} tool-status-failed"
      true -> "#{base} tool-status-completed"
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
