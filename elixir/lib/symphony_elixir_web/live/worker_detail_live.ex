defmodule SymphonyElixirWeb.WorkerDetailLive do
  @moduledoc """
  Worker Details page — chat-style view of a Codex worker session backed by
  on-disk Codex rollout JSONL files.

  ## Why this is its own module (vs staying in DashboardLive)

  The detail action grew complex enough — sidebar, tabs, streamed transcript,
  per-rollout PubSub subscriptions, file-tail server lifecycle — that mixing
  it with the index dashboard was hurting both. Splitting follows the
  general LiveView guidance of one module per route.

  ## Data flow

  ```
  mount -> Presenter.issue_payload/3 (orchestrator + RolloutIndex fallback)
        -> assigns: detail_payload, rollouts list, current_rollout
        -> stream :transcript = RolloutReader.stream(current_rollout.path)
                                |> map(to_conversation_item) |> reject(nil)
        -> CodexTailServer.subscribe(rollout_id: ..., path: ...)
  ```

  Live updates arrive as `{:rollout_item, _, item}` and are streamed in
  with `phx-update="stream"`. Switching rollouts is a `stream(..., reset:
  true)` plus an unsubscribe/subscribe cycle.

  Hidden by design: developer/system role messages, low-signal protocol
  events. The classifier in `RolloutReader.to_conversation_item/1` is the
  single source of truth for that taxonomy.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Codex.RolloutReader
  alias SymphonyElixirWeb.{CodexTailServer, Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(%{"issue_identifier" => issue_identifier} = params, _session, socket) do
    socket =
      socket
      |> assign(:issue_identifier, issue_identifier)
      |> assign(:tab, normalize_tab(params["tab"]))
      |> assign(:detail_payload, nil)
      |> assign(:detail_error, nil)
      |> assign(:current_rollout, nil)
      |> assign(:rollouts, [])
      |> assign(:transcript_count, 0)
      |> assign(:steer_auth_required, steer_auth_required?())
      |> assign(:steer_token_configured, steer_token_configured?())
      |> assign(:now, DateTime.utc_now())
      |> stream(:transcript, [])

    socket =
      if connected?(socket) do
        :ok = ObservabilityPubSub.subscribe()
        schedule_runtime_tick()
        load_detail(socket, params["rollout"])
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:tab, normalize_tab(params["tab"]))
      |> maybe_switch_rollout(params["rollout"])

    {:noreply, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(:observability_updated, socket) do
    # Refresh sidebar / sidebar metrics; do not reset the transcript stream.
    {:noreply, refresh_payload(socket)}
  end

  def handle_info({:rollout_item, rid, item}, socket) do
    if current_rollout_id(socket) == rid do
      {:noreply,
       socket
       |> stream_insert(:transcript, conversation_item_to_row(item, socket.assigns.transcript_count))
       |> update(:transcript_count, &(&1 + 1))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:rollout_state, rid, :truncated}, socket) do
    if current_rollout_id(socket) == rid,
      do: {:noreply, reload_transcript(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ---- events ------------------------------------------------------------

  @impl true
  def handle_event("steer", %{"steer" => steer_params}, socket) do
    issue_identifier = socket.assigns.issue_identifier
    message = Map.get(steer_params, "message", "")
    session_id = Map.get(steer_params, "session_id")
    operator_token = Map.get(steer_params, "operator_token")

    case authorize_steer(operator_token) do
      :ok -> submit_steer(socket, issue_identifier, message, session_id)
      {:error, reason} -> {:noreply, put_flash(socket, :error, steer_error_message(reason))}
    end
  end

  defp submit_steer(socket, issue_identifier, message, session_id) do
    cond do
      not non_blank_binary?(message) ->
        {:noreply, put_flash(socket, :error, steer_error_message(:blank_message))}

      not non_blank_binary?(session_id) ->
        {:noreply, put_flash(socket, :error, steer_error_message(:session_mismatch))}

      true ->
        case Presenter.steer_payload(issue_identifier, message, session_id, orchestrator()) do
          {:ok, _payload} ->
            {:noreply, put_flash(socket, :info, "Steer queued for #{issue_identifier}.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, steer_error_message(reason))}
        end
    end
  end

  # ---- view --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <section class="worker-shell">
      <header class="worker-header">
        <a class="worker-back" href="/">‹ Dashboard</a>
        <span class="worker-id"><%= @issue_identifier %></span>
        <%= if @detail_payload do %>
          <span class="worker-title"><%= @detail_payload.title || @detail_payload.workspace.path %></span>
          <span class={state_badge_class(@detail_payload.status)}><%= @detail_payload.status %></span>
          <%= if @detail_payload.status in ["running", "retrying"] do %>
            <span class="worker-live"><span class="worker-live-dot"></span>live</span>
          <% end %>
        <% end %>
      </header>

      <%= if @detail_error do %>
        <section class="worker-error">
          <h2 class="error-title">Worker unavailable</h2>
          <p class="error-copy"><%= @detail_error %></p>
        </section>
      <% else %>
        <% detail = @detail_payload || empty_detail(@issue_identifier) %>

        <div class="worker-grid">
          <aside class="worker-sidebar">
            <section class="worker-sidebar-section">
              <h3 class="worker-section-title">Rollouts</h3>
              <%= if @rollouts == [] do %>
                <p class="worker-section-empty">No rollouts on disk.</p>
              <% else %>
                <ol class="rollout-list">
                  <li
                    :for={r <- @rollouts}
                    class={["rollout-row", current_rollout_class(@current_rollout, r)]}
                  >
                    <a
                      class="rollout-link"
                      href={rollout_link(@issue_identifier, r, @tab)}
                    >
                      <span class="rollout-row-title"><%= rollout_label(r) %></span>
                      <span class="rollout-row-meta"><%= r.started_at || "—" %></span>
                    </a>
                  </li>
                </ol>
              <% end %>
            </section>

            <section class="worker-sidebar-section">
              <h3 class="worker-section-title">Status</h3>
              <dl class="worker-kv">
                <div><dt>State</dt><dd><%= detail.status %></dd></div>
                <div><dt>Session</dt><dd class="mono"><%= session_id_label(detail) %></dd></div>
                <div><dt>Turn</dt><dd><%= turn_label(detail) %></dd></div>
                <div><dt>Branch</dt><dd class="detail-path"><%= detail.workspace.branch || "—" %></dd></div>
                <div><dt>Workspace</dt><dd class="detail-path"><%= detail.workspace.path || "—" %></dd></div>
                <div :if={detail.pull_request}><dt>PR</dt><dd><a href={detail.pull_request.url} target="_blank" rel="noopener"><%= detail.pull_request.url %></a></dd></div>
                <div :if={tokens(detail)}><dt>Tokens</dt><dd class="numeric"><%= format_tokens(tokens(detail)) %></dd></div>
              </dl>
            </section>
          </aside>

          <section class="worker-main">
            <nav class="worker-tabs" aria-label="Worker views">
              <a
                :for={tab <- tabs()}
                class={tab_class(@tab, tab.id)}
                href={tab_link(@issue_identifier, @current_rollout, tab.id)}
              ><%= tab.label %></a>
            </nav>

            <%= case @tab do %>
              <% :transcript -> %>
                <.transcript_panel
                  detail={detail}
                  current_rollout={@current_rollout}
                  transcript_count={@transcript_count}
                  steer_auth_required={@steer_auth_required}
                  steer_token_configured={@steer_token_configured}
                  streams={@streams}
                />

              <% :logs -> %>
                <.logs_panel detail={detail} />

              <% :workspace -> %>
                <.workspace_panel detail={detail} />

              <% :pr -> %>
                <.pr_panel detail={detail} />
            <% end %>
          </section>
        </div>
      <% end %>
    </section>
    """
  end

  # ---- panels ------------------------------------------------------------

  attr :detail, :map, required: true
  attr :current_rollout, :map, default: nil
  attr :transcript_count, :integer, default: 0
  attr :steer_auth_required, :boolean, required: true
  attr :steer_token_configured, :boolean, required: true
  attr :streams, :map, required: true

  defp transcript_panel(assigns) do
    ~H"""
    <div class="transcript-shell">
      <div class="transcript-meta">
        <span><%= @transcript_count %> items</span>
        <%= if @current_rollout do %>
          · <span class="mono"><%= rollout_label(@current_rollout) %></span>
          <%= if @current_rollout.started_at do %>
            · <span class="mono"><%= @current_rollout.started_at %></span>
          <% end %>
        <% end %>
      </div>

      <div
        id="worker-transcript-scroll"
        class="transcript-scroll"
        phx-hook="StickyScroll"
      >
        <ol id="worker-transcript" phx-update="stream" class="transcript">
          <%= if @transcript_count == 0 and @current_rollout == nil do %>
            <li id="transcript-empty" class="transcript-empty">No rollout selected. The orchestrator has nothing on disk for this issue yet.</li>
          <% end %>
          <li
            :for={{dom_id, item} <- @streams.transcript}
            id={dom_id}
            class={["transcript-item", "tr-" <> Atom.to_string(item.kind)]}
          >
            <div class="transcript-marker"><%= marker_for(item.kind) %></div>
            <div class="transcript-body">
              <div class="transcript-meta-row">
                <span class="transcript-kind"><%= label_for(item.kind) %></span>
                <span class="transcript-time mono"><%= format_at(item.at) %></span>
              </div>
              <%= cond do %>
                <% item.kind == :reasoning and String.length(item.text) > 200 -> %>
                  <details class="transcript-details">
                    <summary class="transcript-summary"><%= preview_text(item.text) %></summary>
                    <pre class="transcript-pre"><%= item.text %></pre>
                  </details>
                <% item.kind == :tool_call -> %>
                  <details class="transcript-details">
                    <summary class="transcript-summary"><%= item.text %></summary>
                    <pre class="transcript-pre"><%= format_tool_meta(item) %></pre>
                  </details>
                <% true -> %>
                  <p class="transcript-text"><%= item.text %></p>
              <% end %>
            </div>
          </li>
        </ol>
      </div>

      <%= cond do %>
        <% @steer_auth_required and not @steer_token_configured -> %>
          <p class="composer-disabled">Steering is locked — this dashboard is exposed without an operator token.</p>

        <% @detail.running -> %>
          <.form for={%{}} as={:steer} phx-submit="steer" class="composer-form">
            <input type="hidden" name="steer[session_id]" value={session_id_or_empty(@detail)} />
            <%= if @steer_auth_required and @steer_token_configured do %>
              <input
                type="password"
                name="steer[operator_token]"
                class="steer-token"
                placeholder="Operator token"
                autocomplete="off"
              />
            <% end %>
            <div class="composer-row">
              <textarea
                name="steer[message]"
                class="composer-input"
                rows="2"
                placeholder="Steer the agent…"
              ></textarea>
              <button type="submit">Send</button>
            </div>
          </.form>

        <% true -> %>
          <p class="composer-disabled">Worker is not running — steering is disabled.</p>
      <% end %>
    </div>
    """
  end

  attr :detail, :map, required: true

  defp logs_panel(assigns) do
    ~H"""
    <div class="panel-shell">
      <h3 class="worker-section-title">Codex session logs</h3>
      <%= if logs(@detail) == [] do %>
        <p class="empty-state">No logs registered for this issue.</p>
      <% else %>
        <ul class="log-list">
          <li :for={log <- logs(@detail)}>
            <span class="mono"><%= log.label || "(unnamed)" %></span>
            <code class="detail-path"><%= log.path %></code>
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  attr :detail, :map, required: true

  defp workspace_panel(assigns) do
    ~H"""
    <div class="panel-shell">
      <h3 class="worker-section-title">Workspace</h3>
      <dl class="worker-kv worker-kv-wide">
        <div><dt>Path</dt><dd class="detail-path"><%= @detail.workspace.path || "—" %></dd></div>
        <div><dt>Host</dt><dd><%= @detail.workspace.host || "local" %></dd></div>
        <div><dt>Branch</dt><dd class="detail-path"><%= @detail.workspace.branch || "—" %></dd></div>
      </dl>
    </div>
    """
  end

  attr :detail, :map, required: true

  defp pr_panel(assigns) do
    ~H"""
    <div class="panel-shell">
      <h3 class="worker-section-title">Pull request</h3>
      <%= if @detail.pull_request do %>
        <p><a href={@detail.pull_request.url} target="_blank" rel="noopener"><%= @detail.pull_request.url %></a></p>
        <%= if @detail.checks do %>
          <p class="muted">Checks: <%= inspect(@detail.checks.summary) %></p>
        <% end %>
      <% else %>
        <p class="empty-state">No pull request linked.</p>
      <% end %>
    </div>
    """
  end

  # ---- data helpers ------------------------------------------------------

  defp load_detail(socket, requested_rollout) do
    case Presenter.issue_payload(socket.assigns.issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        rollouts = Map.get(payload, :rollouts, [])
        current = pick_rollout(rollouts, requested_rollout) || Map.get(payload, :current_rollout)

        socket
        |> assign(:detail_payload, payload)
        |> assign(:detail_error, nil)
        |> assign(:rollouts, rollouts)
        |> set_current_rollout(current)

      {:error, :issue_not_found} ->
        socket
        |> assign(:detail_payload, nil)
        |> assign(:detail_error, "No worker history found for #{socket.assigns.issue_identifier}.")
    end
  end

  defp refresh_payload(socket) do
    case Presenter.issue_payload(socket.assigns.issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        socket
        |> assign(:detail_payload, payload)
        |> assign(:rollouts, Map.get(payload, :rollouts, []))

      {:error, _} ->
        socket
    end
  end

  defp maybe_switch_rollout(socket, requested) do
    target = pick_rollout(socket.assigns.rollouts, requested) || socket.assigns.current_rollout

    cond do
      is_nil(target) -> socket
      same_rollout?(socket.assigns.current_rollout, target) -> socket
      true -> set_current_rollout(socket, target)
    end
  end

  defp set_current_rollout(socket, nil) do
    socket
    |> assign(:current_rollout, nil)
    |> stream(:transcript, [], reset: true)
    |> assign(:transcript_count, 0)
  end

  defp set_current_rollout(socket, rollout) do
    previous = socket.assigns.current_rollout
    rid = rollout_id(rollout)

    if previous && rollout_id(previous) != rid do
      _ = CodexTailServer.unsubscribe(rollout_id: rollout_id(previous))
    end

    items = load_initial_items(rollout)

    rows =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} -> conversation_item_to_row(item, idx) end)

    if connected?(socket) do
      _ = CodexTailServer.subscribe(rollout_id: rid, path: rollout.path)
    end

    socket
    |> assign(:current_rollout, rollout)
    |> stream(:transcript, rows, reset: true)
    |> assign(:transcript_count, length(rows))
  end

  defp reload_transcript(socket) do
    case socket.assigns.current_rollout do
      nil -> socket
      rollout -> set_current_rollout(socket, rollout)
    end
  end

  defp load_initial_items(rollout) do
    rollout.path
    |> RolloutReader.stream()
    |> Stream.map(&RolloutReader.to_conversation_item/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.to_list()
  rescue
    _ -> []
  end

  defp conversation_item_to_row(item, idx) do
    Map.put(item, :id, "tr-#{idx}-#{System.unique_integer([:positive])}")
  end

  defp pick_rollout(_rollouts, nil), do: nil

  defp pick_rollout(rollouts, requested) do
    Enum.find(rollouts, fn r -> rollout_id(r) == requested end)
  end

  defp rollout_id(%{session_id: sid}) when is_binary(sid), do: sid
  defp rollout_id(%{path: path}) when is_binary(path), do: Path.basename(path)
  defp rollout_id(_), do: nil

  defp current_rollout_id(socket), do: rollout_id(socket.assigns.current_rollout)

  defp same_rollout?(a, b), do: rollout_id(a) == rollout_id(b)

  defp rollout_label(%{session_id: sid}) when is_binary(sid),
    do: String.slice(sid, 0, 8)

  defp rollout_label(%{path: path}) when is_binary(path), do: Path.basename(path)
  defp rollout_label(_), do: "(unknown)"

  defp current_rollout_class(nil, _), do: ""
  defp current_rollout_class(current, row), do: if(rollout_id(current) == rollout_id(row), do: "rollout-row-active", else: "")

  defp tabs do
    [
      %{id: :transcript, label: "Transcript"},
      %{id: :logs, label: "Logs"},
      %{id: :workspace, label: "Workspace"},
      %{id: :pr, label: "PR & Linear"}
    ]
  end

  defp tab_class(current, current), do: "worker-tab worker-tab-active"
  defp tab_class(_, _), do: "worker-tab"

  defp normalize_tab("logs"), do: :logs
  defp normalize_tab("workspace"), do: :workspace
  defp normalize_tab("pr"), do: :pr
  defp normalize_tab(_), do: :transcript

  defp tab_link(issue, rollout, tab) do
    base = "/workers/#{issue}"
    qs = build_qs(rollout, tab)
    if qs == "", do: base, else: base <> "?" <> qs
  end

  defp rollout_link(issue, rollout, tab) do
    qs = build_qs(rollout, tab)
    "/workers/#{issue}" <> if qs == "", do: "", else: "?" <> qs
  end

  defp build_qs(rollout, tab) do
    parts =
      []
      |> maybe_add_param("rollout", rollout && rollout_id(rollout))
      |> maybe_add_param("tab", if(tab == :transcript, do: nil, else: Atom.to_string(tab)))

    Enum.join(parts, "&")
  end

  defp maybe_add_param(parts, _key, nil), do: parts
  defp maybe_add_param(parts, key, value), do: parts ++ ["#{key}=#{URI.encode_www_form(to_string(value))}"]

  defp empty_detail(issue) do
    %{
      issue_identifier: issue,
      status: "unknown",
      title: nil,
      workspace: %{path: nil, host: nil, branch: nil},
      pull_request: nil,
      checks: nil,
      running: nil,
      logs: %{codex_session_logs: []}
    }
  end

  defp marker_for(:assistant_message), do: "▸"
  defp marker_for(:user_message), do: "↪"
  defp marker_for(:tool_call), do: "⌘"
  defp marker_for(:reasoning), do: "·"
  defp marker_for(:state_change), do: "—"
  defp marker_for(:error), do: "⚠"
  defp marker_for(_), do: "·"

  defp label_for(:assistant_message), do: "Agent"
  defp label_for(:user_message), do: "You"
  defp label_for(:tool_call), do: "tool"
  defp label_for(:reasoning), do: "thought"
  defp label_for(:state_change), do: "state"
  defp label_for(:error), do: "error"
  defp label_for(other), do: Atom.to_string(other)

  defp format_at(nil), do: "—"
  defp format_at(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp preview_text(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 200)
    |> Kernel.<>(" ▾")
  end

  defp format_tool_meta(%{meta: %{is_output: true}, text: text}), do: text

  defp format_tool_meta(%{meta: meta}) when is_map(meta) do
    args =
      case meta[:arguments] do
        a when is_binary(a) -> a
        a when is_map(a) -> Jason.encode!(a, pretty: true)
        a -> inspect(a)
      end

    "name: #{meta[:name] || "?"}\ncall_id: #{meta[:call_id] || "?"}\narguments:\n#{args}"
  end

  defp format_tool_meta(%{text: text}), do: text

  defp session_id_label(%{running: %{session_id: sid}}) when is_binary(sid), do: sid
  defp session_id_label(_), do: "—"

  defp turn_label(%{running: %{turn_count: n}}) when is_integer(n), do: Integer.to_string(n)
  defp turn_label(_), do: "—"

  defp tokens(%{running: %{tokens: t}}) when is_map(t), do: t
  defp tokens(_), do: nil

  defp format_tokens(%{input_tokens: i, output_tokens: o, total_tokens: t}) do
    "#{format_int(t)} (in #{format_int(i)} / out #{format_int(o)})"
  end

  defp format_tokens(_), do: "—"

  defp format_int(n) when is_integer(n), do: Integer.to_string(n)
  defp format_int(_), do: "—"

  defp logs(%{logs: %{codex_session_logs: list}}), do: list
  defp logs(_), do: []

  defp session_id_or_empty(%{running: %{session_id: sid}}) when is_binary(sid), do: sid
  defp session_id_or_empty(_), do: ""

  defp state_badge_class(state) do
    base = "state-badge"
    n = state |> to_string() |> String.downcase()

    cond do
      n in ["running", "active"] -> "#{base} state-badge-active"
      n in ["retrying", "queued", "pending", "todo"] -> "#{base} state-badge-warning"
      n in ["error", "failed", "blocked"] -> "#{base} state-badge-danger"
      n == "ended" -> "#{base}"
      true -> base
    end
  end

  # ---- auth / config helpers --------------------------------------------

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
          expected -> compare_steer_token(operator_token, expected)
        end

      _ ->
        {:error, :steer_auth_required}
    end
  end

  defp compare_steer_token(operator_token, expected) do
    submitted = String.trim(operator_token || "")

    cond do
      submitted == "" ->
        {:error, :steer_auth_required}

      byte_size(submitted) == byte_size(expected) and Plug.Crypto.secure_compare(submitted, expected) ->
        :ok

      true ->
        {:error, :invalid_steer_token}
    end
  end

  defp non_blank_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_blank_binary?(_), do: false

  defp steer_error_message(:blank_message), do: "Steer message cannot be blank."
  defp steer_error_message(:worker_not_running), do: "Worker is no longer running."
  defp steer_error_message(:session_mismatch), do: "Worker session changed before the steer was sent."
  defp steer_error_message(:steer_auth_required), do: "Operator token is required."
  defp steer_error_message(:invalid_steer_token), do: "Operator token is invalid."
  defp steer_error_message(reason), do: "Steer failed: #{inspect(reason)}"

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
