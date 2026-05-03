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
      |> assign(:filter, :all)
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
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("filter", %{"kind" => kind}, socket) do
    {:noreply, assign(socket, :filter, normalize_filter(kind))}
  end

  def handle_event("reload_runtime", %{"reload" => reload_params}, socket) do
    operator_token = Map.get(reload_params, "operator_token")

    case authorize_reload(operator_token) do
      :ok ->
        case Presenter.request_reload_payload(orchestrator(), snapshot_timeout_ms()) do
          {:ok, payload} ->
            {:noreply,
             socket
             |> put_flash(:info, "Managed reload queued: #{payload.request_id}.")
             |> assign(:payload, load_payload())}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reload_error_message(reason))}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reload_error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="page-shell">
      <header class="page-header dashboard-header">
        <span class="page-brand">Symphony</span>
        <span class="page-brand-sub">Operations</span>
        <%= if @payload[:runtime] && @payload.runtime.commit do %>
          <span class="page-meta mono"><%= short_commit(@payload.runtime.commit) %></span>
        <% end %>
        <span class="page-live">
          <span class="page-live-dot"></span>
          <%= dashboard_freshness_label(@payload[:generated_at], @now) %>
        </span>
        <.form for={%{}} as={:reload} phx-submit="reload_runtime" class="header-reload">
          <%= if @steer_token_configured do %>
            <input
              type="password"
              name="reload[operator_token]"
              class="steer-token"
              placeholder="Operator token"
              autocomplete="off"
            />
          <% end %>
          <button
            type="submit"
            class="secondary"
            disabled={runtime_reload_disabled?(@payload, @steer_auth_required, @steer_token_configured)}
          >Reload runtime</button>
        </.form>
      </header>

      <%= if @payload[:error] do %>
        <section class="page-error">
          <h2 class="error-title">Snapshot unavailable</h2>
          <p class="error-copy"><strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %></p>
        </section>
      <% else %>
        <% running = @payload.running || [] %>
        <% retrying = @payload.retrying || [] %>
        <% retrying_ids = MapSet.new(retrying, & &1.issue_identifier) %>
        <% classified = Enum.map(running, &Map.put(&1, :__triage, triage_classification(&1, retrying_ids))) %>
        <% counts = triage_counts(classified, retrying) %>
        <% alerts = alert_rows(classified) %>
        <% filtered = filter_running(classified, @filter) %>
        <% primary_used = primary_rate_limit_used(@payload.rate_limits) %>

        <div class="page-grid">
          <aside class="page-sidebar">
            <section class="page-sidebar-section dock">
              <h3 class="page-section-title">Capacity</h3>
              <div class="dock-pair">
                <div class="dock-pair-cell">
                  <span class="dock-numeral"><%= counts.running %></span>
                  <span class="dock-numeral-label">running</span>
                </div>
                <div class="dock-pair-cell">
                  <span class="dock-numeral"><%= counts.retrying %></span>
                  <span class="dock-numeral-label">retrying</span>
                </div>
              </div>
              <div class="dock-bar" aria-label="Primary rate limit used">
                <span
                  class={"dock-bar-fill " <> rate_limit_bar_class(primary_used)}
                  style={"width: " <> Integer.to_string(primary_used || 0) <> "%"}
                ></span>
              </div>
              <p class="dock-bar-label"><%= used_label(primary_used) %> · primary rate limit</p>
            </section>

            <section class="page-sidebar-section dock">
              <h3 class="page-section-title">Tokens</h3>
              <p class="dock-numeral numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
              <% in_pct = token_share(@payload.codex_totals.input_tokens, @payload.codex_totals.total_tokens) %>
              <% out_pct = token_share(@payload.codex_totals.output_tokens, @payload.codex_totals.total_tokens) %>
              <div class="dock-bar dock-bar-split" aria-label="Token in/out share">
                <span class="dock-bar-input" style={"width: " <> Integer.to_string(in_pct) <> "%"}></span>
                <span class="dock-bar-output" style={"width: " <> Integer.to_string(out_pct) <> "%"}></span>
              </div>
              <p class="dock-bar-label numeric">
                in <%= format_int(@payload.codex_totals.input_tokens) %>
                · out <%= format_int(@payload.codex_totals.output_tokens) %>
              </p>
            </section>

            <section class="page-sidebar-section">
              <h3 class="page-section-title">Runtime</h3>
              <dl class="page-kv">
                <div>
                  <dt>Commit</dt>
                  <dd class="mono"><%= short_commit(@payload.runtime.commit) %> · <%= @payload.runtime.branch || "detached" %></dd>
                </div>
                <div>
                  <dt>Port</dt>
                  <dd class="mono"><%= @payload.runtime.port || "n/a" %></dd>
                </div>
                <div>
                  <dt>PID</dt>
                  <dd class="mono"><%= @payload.runtime.os_pid || "n/a" %></dd>
                </div>
                <div>
                  <dt>Up</dt>
                  <dd><%= uptime_label(@payload.runtime.started_at, @now) %></dd>
                </div>
              </dl>
            </section>

            <section class="page-sidebar-section">
              <h3 class="page-section-title">Cleanup</h3>
              <p class="dock-bar-label"><%= workspace_cleanup_summary(@payload.workspace_cleanup) %></p>
              <dl class="page-kv">
                <div>
                  <dt>Cleaned</dt>
                  <dd class="numeric"><%= format_int(workspace_cleanup_value(@payload.workspace_cleanup, :cleaned)) %></dd>
                </div>
                <div>
                  <dt>Kept</dt>
                  <dd class="numeric"><%= format_int(workspace_cleanup_value(@payload.workspace_cleanup, :preserved)) %></dd>
                </div>
                <div>
                  <dt>TTL</dt>
                  <dd><%= workspace_cleanup_ttl(@payload.workspace_cleanup) %></dd>
                </div>
              </dl>
            </section>
          </aside>

          <section class="page-main">
            <%= if alerts != [] do %>
              <ul class="alert-banner">
                <li :for={a <- alerts} class={"alert-row alert-row-" <> Atom.to_string(a.tone)}>
                  <a href={"/workers/" <> a.identifier}>
                    <span class="alert-marker"><%= a.marker %></span>
                    <span class="alert-id mono"><%= a.identifier %></span>
                    <span class="alert-text"><%= a.text %></span>
                    <span class="alert-cta">→</span>
                  </a>
                </li>
              </ul>
            <% end %>

            <nav class="triage-chips" aria-label="Filter active workers">
              <button
                type="button"
                phx-click="filter"
                phx-value-kind="all"
                class={chip_class(@filter, :all)}
              >All <span class="chip-count"><%= counts.total_visible %></span></button>
              <button
                type="button"
                phx-click="filter"
                phx-value-kind="stalled"
                class={chip_class(@filter, :stalled)}
                disabled={counts.stalled == 0}
              >⚠ stalled <span class="chip-count"><%= counts.stalled %></span></button>
              <button
                type="button"
                phx-click="filter"
                phx-value-kind="retrying"
                class={chip_class(@filter, :retrying)}
                disabled={counts.retrying == 0}
              >↻ retrying <span class="chip-count"><%= counts.retrying %></span></button>
              <button
                type="button"
                phx-click="filter"
                phx-value-kind="errored"
                class={chip_class(@filter, :errored)}
                disabled={counts.errored == 0}
              >✕ errored <span class="chip-count"><%= counts.errored %></span></button>
            </nav>

            <section class="row-section">
              <header class="row-section-header">
                <h2 class="page-section-title">Active workers</h2>
                <span class="row-section-meta">
                  <%= if @filter == :all do %>
                    <%= length(filtered) %> of <%= length(classified) %>
                  <% else %>
                    filtered: <%= length(filtered) %>
                  <% end %>
                </span>
              </header>
              <%= if filtered == [] do %>
                <p class="row-empty">
                  <%= if classified == [], do: "No active workers.", else: "No workers match this filter." %>
                </p>
              <% else %>
                <ol class="row-list">
                  <li
                    :for={entry <- filtered}
                    class={"row row-" <> Atom.to_string(entry.__triage)}
                  >
                    <a class="row-link" href={"/workers/" <> entry.issue_identifier}>
                      <span class="row-marker"><%= triage_marker(entry.__triage) %></span>
                      <div class="row-body">
                        <div class="row-line-1">
                          <span class="row-id mono"><%= entry.issue_identifier %></span>
                          <%= if entry.title do %>
                            <span class="row-title"><%= entry.title %></span>
                          <% end %>
                          <span class={state_badge_class(entry.state)}><%= entry.state %></span>
                        </div>
                        <div class="row-line-2 muted">
                          <span class="mono"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></span>
                          <%= if entry.command_watchdog do %>
                            <span class="row-pip">·</span>
                            <span class="mono">watchdog <%= entry.command_watchdog.classification %> · <%= format_watchdog_age(entry.command_watchdog.age_ms) %></span>
                          <% end %>
                          <%= if entry.last_message || entry.last_event do %>
                            <span class="row-pip">·</span>
                            <span class="row-last"><%= entry.last_message || to_string(entry.last_event) %></span>
                          <% end %>
                        </div>
                      </div>
                      <div class="row-tokens">
                        <% rin = token_share(entry.tokens.input_tokens, entry.tokens.total_tokens) %>
                        <% rout = token_share(entry.tokens.output_tokens, entry.tokens.total_tokens) %>
                        <div class="row-tokens-bar" aria-label="Token in/out share">
                          <span class="row-tokens-input" style={"width: " <> Integer.to_string(rin) <> "%"}></span>
                          <span class="row-tokens-output" style={"width: " <> Integer.to_string(rout) <> "%"}></span>
                        </div>
                        <span class="row-tokens-label numeric"><%= format_int(entry.tokens.total_tokens) %></span>
                      </div>
                    </a>
                  </li>
                </ol>
              <% end %>
            </section>

            <section class="row-section">
              <header class="row-section-header">
                <h2 class="page-section-title">Retry queue</h2>
                <span class="row-section-meta"><%= length(retrying) %></span>
              </header>
              <%= if retrying == [] do %>
                <p class="row-empty">No retries.</p>
              <% else %>
                <ol class="row-list">
                  <li :for={r <- retrying} class="row row-retrying">
                    <a class="row-link" href={"/api/v1/" <> r.issue_identifier}>
                      <span class="row-marker">↻</span>
                      <div class="row-body">
                        <div class="row-line-1">
                          <span class="row-id mono"><%= r.issue_identifier %></span>
                          <span class="row-title">attempt <%= r.attempt %> · <%= r.error_kind || "error" %></span>
                        </div>
                        <div class="row-line-2 muted">
                          <span class="mono">due <%= r.due_at || "n/a" %></span>
                          <%= if r.branch_name do %>
                            <span class="row-pip">·</span>
                            <span class="mono"><%= r.branch_name %></span>
                          <% end %>
                          <%= if r.error do %>
                            <span class="row-pip">·</span>
                            <span class="row-last"><%= r.error %></span>
                          <% end %>
                        </div>
                      </div>
                    </a>
                  </li>
                </ol>
              <% end %>
            </section>

            <details id="system-debug" class="system-debug" phx-hook="PreserveDetails">
              <summary>System debug</summary>
              <div class="system-debug-body">
                <h4 class="page-section-title">Workflow</h4>
                <p class="detail-path"><%= @payload.runtime.workflow_path || "n/a" %></p>
                <h4 class="page-section-title">Last reload</h4>
                <p><%= reload_status(@payload.runtime.reload) %> — <%= reload_message(@payload.runtime.reload) %></p>
                <h4 class="page-section-title">Rate limits (raw)</h4>
                <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
                <h4 class="page-section-title">Generated</h4>
                <p class="mono"><%= @payload.generated_at %></p>
              </div>
            </details>
          </section>
        </div>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
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

  defp authorize_reload(operator_token) do
    if steer_auth_required?() do
      authorize_reload_token(operator_token, Endpoint.config(:steer_token))
    else
      :ok
    end
  end

  defp authorize_reload_token(operator_token, token) when is_binary(token) do
    expected = String.trim(token)
    submitted = String.trim(operator_token || "")

    cond do
      expected == "" -> {:error, :steer_auth_required}
      submitted == "" -> {:error, :steer_auth_required}
      token_match?(submitted, expected) -> :ok
      true -> {:error, :invalid_steer_token}
    end
  end

  defp authorize_reload_token(_operator_token, _token), do: {:error, :steer_auth_required}

  defp token_match?(submitted, expected) do
    byte_size(submitted) == byte_size(expected) and
      Plug.Crypto.secure_compare(submitted, expected)
  end

  ## --- triage / classification --------------------------------------------

  # Single source of truth for which workers count as stalled / errored / etc.
  # Mirrors `watchdog_badge_class/1`'s rules so badge color and triage marker
  # stay in sync.
  defp triage_classification(running, retrying_ids) do
    cond do
      MapSet.member?(retrying_ids, running.issue_identifier) -> :retrying
      errored_state?(running.state) -> :errored
      stalled_watchdog?(running.command_watchdog) -> :stalled
      idle_watchdog?(running.command_watchdog) -> :idle
      true -> :healthy
    end
  end

  defp errored_state?(state) do
    s = state |> to_string() |> String.downcase()
    String.contains?(s, ["error", "failed", "blocked"])
  end

  defp stalled_watchdog?(%{classification: c}), do: to_string(c) == "stalled"
  defp stalled_watchdog?(_), do: false

  defp idle_watchdog?(%{classification: c}) do
    s = to_string(c)
    s == "idle" or s == "needs_attention"
  end

  defp idle_watchdog?(_), do: false

  defp triage_counts(classified, retrying) do
    grouped = Enum.frequencies_by(classified, & &1.__triage)

    %{
      running: length(classified),
      retrying: length(retrying),
      stalled: Map.get(grouped, :stalled, 0),
      errored: Map.get(grouped, :errored, 0),
      idle: Map.get(grouped, :idle, 0),
      healthy: Map.get(grouped, :healthy, 0),
      total_visible: length(classified)
    }
  end

  defp filter_running(classified, :all), do: classified
  defp filter_running(classified, :retrying), do: Enum.filter(classified, &(&1.__triage == :retrying))
  defp filter_running(classified, kind), do: Enum.filter(classified, &(&1.__triage == kind))

  defp normalize_filter("stalled"), do: :stalled
  defp normalize_filter("retrying"), do: :retrying
  defp normalize_filter("errored"), do: :errored
  defp normalize_filter(_), do: :all

  defp alert_rows(classified) do
    classified
    |> Enum.filter(&(&1.__triage in [:stalled, :errored, :idle]))
    |> Enum.map(fn entry ->
      %{
        identifier: entry.issue_identifier,
        marker: triage_marker(entry.__triage),
        tone: alert_tone(entry.__triage),
        text: alert_text(entry)
      }
    end)
  end

  defp alert_tone(:errored), do: :danger
  defp alert_tone(:stalled), do: :warning
  defp alert_tone(:idle), do: :muted
  defp alert_tone(_), do: :muted

  defp alert_text(%{__triage: :stalled, command_watchdog: %{idle_ms: idle}}) when is_integer(idle),
    do: "stalled · idle " <> format_watchdog_age(idle)

  defp alert_text(%{__triage: :stalled}), do: "stalled"
  defp alert_text(%{__triage: :idle, command_watchdog: %{classification: c}}), do: "watchdog #{c}"
  defp alert_text(%{__triage: :errored, state: state}), do: "state: #{state}"
  defp alert_text(_), do: "needs attention"

  defp triage_marker(:healthy), do: "▸"
  defp triage_marker(:idle), do: "·"
  defp triage_marker(:stalled), do: "⚠"
  defp triage_marker(:errored), do: "✕"
  defp triage_marker(:retrying), do: "↻"

  defp chip_class(active, active), do: "chip chip-active"
  defp chip_class(_, _), do: "chip"

  ## --- token bar ----------------------------------------------------------

  defp token_share(_part, total) when total in [nil, 0], do: 0
  defp token_share(nil, _total), do: 0

  defp token_share(part, total) when is_integer(part) and is_integer(total) and total > 0,
    do: part |> Kernel./(total) |> Kernel.*(100) |> round() |> max(0) |> min(100)

  defp token_share(_, _), do: 0

  ## --- header / freshness -------------------------------------------------

  defp dashboard_freshness_label(nil, _now), do: "live"

  defp dashboard_freshness_label(generated_at, %DateTime{} = now) when is_binary(generated_at) do
    case DateTime.from_iso8601(generated_at) do
      {:ok, parsed, _offset} ->
        diff = DateTime.diff(now, parsed, :second)
        if diff <= 1, do: "live", else: "live · refreshed " <> relative_duration(max(diff, 0)) <> " ago"

      _ ->
        "live"
    end
  end

  defp dashboard_freshness_label(_, _), do: "live"

  defp uptime_label(nil, _now), do: "n/a"

  defp uptime_label(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> format_runtime_seconds(max(DateTime.diff(now, parsed, :second), 0))
      _ -> "n/a"
    end
  end

  defp uptime_label(_, _), do: "n/a"

  defp primary_rate_limit_used(rate_limits) do
    used_percent(field_value(rate_limits || %{}, [:primary, "primary"]))
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

  defp workspace_cleanup_summary(%{} = cleanup) do
    completed_at = field_value(cleanup, [:completed_at, "completed_at"])
    error = field_value(cleanup, [:error, "error"])

    cond do
      is_binary(error) and error != "" -> "Last cleanup failed: #{error}"
      is_binary(completed_at) -> "Last cleanup completed at #{completed_at}."
      true -> "Cleanup has started and is reporting progress."
    end
  end

  defp workspace_cleanup_summary(_cleanup), do: "Cleanup has not reported status yet."

  defp workspace_cleanup_value(%{} = cleanup, key) do
    field_value(cleanup, [key, Atom.to_string(key)])
  end

  defp workspace_cleanup_value(_cleanup, _key), do: nil

  defp workspace_cleanup_ttl(%{} = cleanup), do: cleanup |> workspace_cleanup_value(:ttl_ms) |> duration_label_from_ms()
  defp workspace_cleanup_ttl(_cleanup), do: "n/a"

  defp duration_label_from_ms(ms) when is_integer(ms) and ms >= 86_400_000, do: "#{div(ms, 86_400_000)}d"
  defp duration_label_from_ms(ms) when is_integer(ms) and ms >= 3_600_000, do: "#{div(ms, 3_600_000)}h"
  defp duration_label_from_ms(ms) when is_integer(ms) and ms >= 60_000, do: "#{div(ms, 60_000)}m"
  defp duration_label_from_ms(ms) when is_integer(ms), do: "#{ms}ms"
  defp duration_label_from_ms(_ms), do: "n/a"

  defp runtime_reload_disabled?(payload, _auth_required?, token_configured?) do
    Map.get(payload, :error) != nil or
      Map.get(payload, :running, []) != [] or
      get_in(payload, [:runtime, :dirty?]) == true or
      not token_configured?
  end

  defp short_commit(commit) when is_binary(commit) and byte_size(commit) >= 7, do: String.slice(commit, 0, 7)
  defp short_commit(_commit), do: "n/a"

  defp reload_status(%{} = reload), do: reload[:status] || reload["status"] || "unknown"
  defp reload_status(_reload), do: "none"

  defp reload_message(%{} = reload) do
    reload[:message] || reload["message"] || reload[:updated_at] || reload["updated_at"] || "No reload message recorded."
  end

  defp reload_message(_reload), do: "No managed reload has run yet."

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

  defp rate_limit_bar_class(value) when is_integer(value) and value >= 90,
    do: "rate-limit-bar-fill rate-limit-bar-fill-danger"

  defp rate_limit_bar_class(value) when is_integer(value) and value >= 70,
    do: "rate-limit-bar-fill rate-limit-bar-fill-warning"

  defp rate_limit_bar_class(_value), do: "rate-limit-bar-fill"

  defp relative_duration(seconds) when seconds >= 86_400, do: "#{div(seconds, 86_400)}d"
  defp relative_duration(seconds) when seconds >= 3_600, do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
  defp relative_duration(seconds) when seconds >= 60, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp relative_duration(seconds), do: "#{seconds}s"

  defp reload_error_message({:active_workers, count}), do: "Reload is blocked while #{count} worker(s) are active."
  defp reload_error_message(:dirty_repo), do: "Reload is blocked because the runtime checkout has uncommitted changes."
  defp reload_error_message(:reload_in_progress), do: "Reload is already queued or running."
  defp reload_error_message(:snapshot_timeout), do: "Reload could not inspect active workers before timing out."
  defp reload_error_message(:snapshot_unavailable), do: "Reload could not inspect active workers."
  defp reload_error_message(:steer_auth_required), do: "Reload requires an operator token."
  defp reload_error_message(:invalid_steer_token), do: "Reload operator token is invalid."
  defp reload_error_message(reason), do: "Reload failed: #{inspect(reason)}"

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

  defp format_watchdog_age(age_ms) when is_integer(age_ms) do
    age_ms
    |> div(1_000)
    |> format_runtime_seconds()
  end

  defp format_watchdog_age(_age_ms), do: "n/a"

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
