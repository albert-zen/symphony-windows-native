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
    case Presenter.steer_payload(issue_identifier, message, session_id, orchestrator()) do
      {:ok, _payload} ->
        {:noreply,
         socket
         |> put_flash(:info, "Steer message queued for #{issue_identifier}.")
         |> assign_detail_payload(issue_identifier)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, steer_error_message(reason))}
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
              <p class="hero-copy">
                Human-readable Codex session activity, raw event details, and targeted manager steering.
              </p>
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
              <p class="metric-label">Tokens</p>
              <p class="metric-value numeric"><%= format_int(running.tokens.total_tokens) %></p>
              <p class="metric-detail numeric">
                In <%= format_int(running.tokens.input_tokens) %> / Out <%= format_int(running.tokens.output_tokens) %>
              </p>
            </article>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Steer worker</h2>
                <p class="section-copy">
                  <%= if detail.running do %>
                    <%= if @steer_auth_required and not @steer_token_configured do %>
                      Steering is locked because this dashboard is exposed without an operator token.
                    <% else %>
                      Send an auditable manager message to this exact active session.
                    <% end %>
                  <% else %>
                    This worker is not running, so steering is disabled.
                  <% end %>
                </p>
              </div>
            </div>

            <.form for={%{}} as={:steer} phx-submit="steer" class="steer-form">
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
              <textarea
                name="steer[message]"
                class="steer-input"
                rows="4"
                placeholder="Send a targeted instruction to this running worker"
                disabled={is_nil(running.session_id) or steer_locked?(@steer_auth_required, @steer_token_configured)}
              ></textarea>
              <button
                type="submit"
                disabled={is_nil(running.session_id) or steer_locked?(@steer_auth_required, @steer_token_configured)}
              >Send steer</button>
            </.form>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Timeline</h2>
                <p class="section-copy">Readable Codex updates with raw JSON preserved per event.</p>
              </div>
            </div>

            <%= if detail.timeline == [] do %>
              <p class="empty-state">No Codex events recorded yet.</p>
            <% else %>
              <ol class="timeline-list">
                <li :for={event <- detail.timeline} class="timeline-item">
                  <div class="timeline-main">
                    <span class="timeline-event"><%= event_label(event.event) %></span>
                    <span class="timeline-time mono"><%= event.at || "pending" %></span>
                  </div>
                  <p class="timeline-message"><%= event.message || "n/a" %></p>
                  <details class="raw-details">
                    <summary>Raw JSON</summary>
                    <pre class="code-panel"><%= pretty_value(event.raw) %></pre>
                  </details>
                </li>
              </ol>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Raw worker payload</h2>
                <p class="section-copy">Full JSON projection used by the detail page.</p>
              </div>
            </div>
            <pre class="code-panel"><%= pretty_value(detail) %></pre>
          </section>
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
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
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
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
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
                    <th>Due at</th>
                    <th>Error</th>
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
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
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

  defp steer_locked?(true, false), do: true
  defp steer_locked?(_required, _configured), do: false

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
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

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp event_label(event) when is_atom(event), do: event |> Atom.to_string() |> String.replace("_", " ")
  defp event_label(event), do: event |> to_string() |> String.replace("_", " ")

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

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
