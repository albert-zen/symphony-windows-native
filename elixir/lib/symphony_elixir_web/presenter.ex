defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Codex.RolloutIndex, Deployment.Reload, Orchestrator, Redactor, RuntimeInfo, StatusDashboard}
  alias SymphonyElixirWeb.WorkerApi

  @conversation_display_limit 120
  @conversation_event_scan_limit 400
  @text_excerpt_chars 2_000
  @raw_excerpt_chars 1_500
  @raw_json_parse_chars 16_000
  @raw_items_per_display_item 8
  @debug_sensitive_key_pattern ~r/(api[_-]?key|authorization|bearer|cookie|credential|password|private[_-]?key|secret|^token$|[_-]token$|token[_-]|access[_-]?token|refresh[_-]?token|session[_-]?token|id[_-]?token)/i
  @debug_open_json_secret_field_pattern Regex.compile!(
                                          ~s/("[^"]*(?:api[_-]?key|authorization|bearer|cookie|credential|password|private[_-]?key|secret|token)[^"]*"\\s*:\\s*")[^"]*\\z/,
                                          "i"
                                        )
  @debug_open_assignment_pattern ~r/\b([A-Za-z0-9_]*(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|PRIVATE[_-]?KEY|CREDENTIAL)[A-Za-z0-9_]*)=[^\s&]*\z/i

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits,
          workspace_cleanup: Map.get(snapshot, :workspace_cleanup),
          runtime: runtime_payload()
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    rollouts = lookup_rollouts(issue_identifier)

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        cond do
          not is_nil(running) or not is_nil(retry) ->
            payload =
              issue_identifier
              |> issue_payload_body(running, retry)
              |> attach_rollouts(rollouts)

            {:ok, payload}

          rollouts != [] ->
            {:ok, historical_issue_payload(issue_identifier, rollouts)}

          true ->
            {:error, :issue_not_found}
        end

      _ ->
        if rollouts == [],
          do: {:error, :issue_not_found},
          else: {:ok, historical_issue_payload(issue_identifier, rollouts)}
    end
  end

  @spec conversation_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def conversation_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok,
           %{
             issue_identifier: issue_identifier,
             status: issue_status(running, retry),
             session: optional_conversation_session(running),
             items: optional_conversation(running)
           }}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec steer_payload(String.t(), String.t(), String.t() | nil, GenServer.name()) ::
          {:ok, map()} | {:error, atom()}
  def steer_payload(issue_identifier, message, expected_session_id, orchestrator)
      when is_binary(issue_identifier) and is_binary(message) do
    case Orchestrator.steer_worker(orchestrator, issue_identifier, message, expected_session_id) do
      {:ok, payload} -> {:ok, Map.update!(payload, :queued_at, &DateTime.to_iso8601/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec runtime_payload() :: map()
  def runtime_payload do
    info = RuntimeInfo.snapshot()

    %{
      cwd: info.cwd,
      repo_root: info.repo_root,
      commit: info.commit,
      branch: info.branch,
      dirty?: info.dirty?,
      workflow_path: info.workflow_path,
      logs_root: info.logs_root,
      pid_file: info.pid_file,
      port: info.port,
      os_pid: info.os_pid,
      started_at: info.started_at,
      reload: Reload.latest_status(info.logs_root)
    }
  end

  @spec request_reload_payload(GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, atom() | {atom(), term()}}
  @spec request_reload_payload(GenServer.name(), timeout(), keyword()) ::
          {:ok, map()} | {:error, atom() | {atom(), term()}}
  def request_reload_payload(orchestrator, snapshot_timeout_ms, opts \\ []) do
    Reload.request(orchestrator, snapshot_timeout_ms, opts)
  end

  @spec worker_conversation([map()]) :: [map()]
  def worker_conversation(events) when is_list(events) do
    events
    |> Enum.take(-@conversation_event_scan_limit)
    |> Enum.reduce([], &append_conversation_event/2)
    |> Enum.reverse()
    |> Enum.take(-@conversation_display_limit)
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    metadata = WorkerApi.worker_metadata(issue_identifier, running, retry)

    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      title: issue_title(running),
      url: issue_url(running),
      status: issue_status(running, retry),
      workspace: metadata.workspace,
      pull_request: metadata.pull_request,
      checks: metadata.checks,
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: optional_running_payload(running),
      retry: optional_retry_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: optional_recent_events(running),
      timeline: optional_timeline(running),
      conversation: optional_conversation(running),
      debug: debug_payload(issue_identifier, running, retry),
      last_error: retry_error(retry),
      tracked: %{}
    }
  end

  defp lookup_rollouts(issue_identifier) do
    RolloutIndex.lookup(issue_identifier)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp attach_rollouts(payload, rollouts) do
    rollout_summaries = Enum.map(rollouts, &rollout_summary/1)

    payload
    |> Map.put(:rollouts, rollout_summaries)
    |> Map.put(:current_rollout, List.first(rollout_summaries))
    |> Map.update(:logs, %{codex_session_logs: rollout_log_paths(rollouts)}, fn logs ->
      Map.put(logs, :codex_session_logs, rollout_log_paths(rollouts))
    end)
  end

  defp historical_issue_payload(issue_identifier, [latest | _] = rollouts) do
    rollout_summaries = Enum.map(rollouts, &rollout_summary/1)

    %{
      issue_identifier: issue_identifier,
      issue_id: nil,
      title: nil,
      url: nil,
      status: "ended",
      workspace: %{path: latest.cwd, host: nil, branch: nil},
      pull_request: nil,
      checks: nil,
      attempts: %{restart_count: nil, current_retry_attempt: nil},
      running: nil,
      retry: nil,
      logs: %{codex_session_logs: rollout_log_paths(rollouts)},
      recent_events: [],
      timeline: [],
      conversation: [],
      debug: nil,
      last_error: nil,
      tracked: %{},
      rollouts: rollout_summaries,
      current_rollout: List.first(rollout_summaries)
    }
  end

  defp rollout_summary(entry) do
    %{
      session_id: entry.session_id,
      path: entry.path,
      cwd: entry.cwd,
      started_at: format_iso(entry.started_at),
      model: entry.model
    }
  end

  defp rollout_log_paths(rollouts) do
    rollouts
    |> Enum.map(fn entry ->
      %{
        label: entry.session_id || Path.basename(entry.path),
        path: entry.path,
        url: nil
      }
    end)
  end

  defp format_iso(nil), do: nil
  defp format_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp issue_title(nil), do: nil
  defp issue_title(running), do: Map.get(running, :title)

  defp issue_url(nil), do: nil
  defp issue_url(running), do: Map.get(running, :url)

  defp optional_running_payload(nil), do: nil
  defp optional_running_payload(running), do: running_issue_payload(running)

  defp optional_retry_payload(nil), do: nil
  defp optional_retry_payload(retry), do: retry_issue_payload(retry)

  defp optional_recent_events(nil), do: []
  defp optional_recent_events(running), do: recent_events_payload(running)

  defp optional_timeline(nil), do: []
  defp optional_timeline(running), do: timeline_payload(running)

  defp optional_conversation(nil), do: []

  defp optional_conversation(running) do
    running
    |> conversation_events()
    |> worker_conversation()
  end

  defp conversation_events(running) do
    case Map.get(running, :completed_agent_messages, []) do
      [_ | _] = messages -> messages
      _ -> Map.get(running, :recent_codex_events, [])
    end
  end

  defp optional_conversation_session(nil), do: nil

  defp optional_conversation_session(running) do
    %{
      session_id: running.session_id,
      thread_id: running.thread_id,
      turn_id: running.turn_id,
      turn_count: running.turn_count
    }
  end

  defp retry_error(nil), do: nil
  defp retry_error(retry), do: retry.error

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      url: Map.get(entry, :url),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      thread_id: Map.get(entry, :thread_id),
      turn_id: Map.get(entry, :turn_id),
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      command_watchdog: command_watchdog_payload(Map.get(entry, :command_watchdog)),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      error_kind: Map.get(entry, :error_kind),
      prior_error: Map.get(entry, :prior_error),
      prior_error_kind: Map.get(entry, :prior_error_kind),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      branch_name: Map.get(entry, :branch_name)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      thread_id: Map.get(running, :thread_id),
      turn_id: Map.get(running, :turn_id),
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      command_watchdog: command_watchdog_payload(Map.get(running, :command_watchdog)),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      error_kind: Map.get(retry, :error_kind),
      prior_error: Map.get(retry, :prior_error),
      prior_error_kind: Map.get(retry, :prior_error_kind),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      branch_name: Map.get(retry, :branch_name)
    }
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp timeline_payload(running) do
    running
    |> Map.get(:recent_codex_events, [])
    |> Enum.take(-@conversation_display_limit)
    |> Enum.map(&timeline_event_payload/1)
  end

  defp timeline_event_payload(event) when is_map(event) do
    %{
      at: iso8601(event[:timestamp]),
      event: event[:event],
      message: summarize_message(event),
      raw: bounded_raw_event_payload(event),
      session_id: event[:session_id],
      thread_id: event[:thread_id],
      turn_id: event[:turn_id]
    }
  end

  defp raw_event_payload(event) when is_map(event) do
    raw = event[:raw]

    cond do
      is_binary(raw) and byte_size(raw) <= @raw_json_parse_chars ->
        case Jason.decode(raw) do
          {:ok, decoded} -> decoded
          _ -> raw
        end

      is_nil(raw) ->
        event[:message]

      true ->
        raw
    end
  end

  defp bounded_raw_event_payload(event) when is_map(event) do
    {excerpt, truncated?} = inspect_bounded(raw_event_payload(event), @raw_excerpt_chars)
    %{excerpt: excerpt, truncated?: truncated?}
  end

  defp debug_payload(issue_identifier, running, retry) do
    payload =
      %{
        issue_identifier: issue_identifier,
        running: optional_running_payload(running),
        retry: optional_retry_payload(retry),
        conversation: optional_conversation(running)
      }

    {excerpt, truncated?} = inspect_bounded(payload, @raw_excerpt_chars)

    %{
      payload_excerpt: excerpt,
      payload_truncated?: truncated?
    }
  end

  defp append_conversation_event(event, items) when is_map(event) do
    raw = raw_event_payload(event)
    payload = display_event_payload(event)
    message = Redactor.redact(event[:message])
    method = event_method(payload) || event_method(raw) || event_method(message)

    event
    |> conversation_event_kind(method, payload, message)
    |> append_classified_conversation_event(event, method, payload, raw, message, items)
  end

  defp append_conversation_event(_event, items), do: items

  defp conversation_event_kind(event, method, payload, message) do
    cond do
      agent_message_completed?(method, payload) -> :assistant_completed
      agent_message_delta?(method) -> :ignore
      command_begin?(method, payload) -> :command_begin
      command_output?(method) -> :command_output
      command_end?(method, payload) -> :command_end
      manager_steer?(event, message) -> :manager_steer
      warning_or_error?(event, message) -> :warning
      true -> :system
    end
  end

  defp append_classified_conversation_event(:assistant_completed, event, method, payload, _raw, _message, items) do
    append_completed_assistant_message(event, method, payload, items)
  end

  defp append_classified_conversation_event(:ignore, _event, _method, _payload, _raw, _message, items) do
    items
  end

  defp append_classified_conversation_event(:command_begin, _event, _method, _payload, _raw, _message, items) do
    items
  end

  defp append_classified_conversation_event(:command_output, _event, _method, _payload, _raw, _message, items) do
    items
  end

  defp append_classified_conversation_event(:command_end, _event, _method, _payload, _raw, _message, items) do
    items
  end

  defp append_classified_conversation_event(:manager_steer, _event, _method, _payload, _raw, _message, items) do
    items
  end

  defp append_classified_conversation_event(:warning, _event, _method, _payload, _raw, _message, items) do
    items
  end

  defp append_classified_conversation_event(:system, _event, _method, _payload, _raw, _message, items) do
    items
  end

  defp append_completed_assistant_message(event, _method, payload, items) do
    text = payload |> extract_completed_agent_text() |> Redactor.redact() |> absorb_redacted_suffix()
    {excerpt, truncated?} = truncate_text(text, @text_excerpt_chars)

    if String.trim(excerpt) == "" do
      items
    else
      append_new_item(
        %{
          type: "assistant",
          key: item_key(event, payload),
          at: iso8601(event[:timestamp]),
          title: "Agent",
          excerpt: excerpt <> if(truncated?, do: "\n[truncated]", else: ""),
          truncated?: truncated?
        },
        items
      )
    end
  end

  defp append_new_item(item, items), do: [item | items]

  defp display_event_payload(event) do
    cond do
      is_map(event[:message]) -> Redactor.redact(event[:message])
      is_map(event[:raw]) -> event[:raw] |> bound_debug_value(@raw_excerpt_chars) |> elem(0)
      true -> Redactor.redact(event[:message])
    end
  end

  defp absorb_redacted_suffix(text) when is_binary(text) do
    Regex.replace(~r/\[REDACTED\][A-Za-z0-9_=\-]+/, text, "[REDACTED]")
  end

  defp event_method(%{} = payload) do
    map_path(payload, ["method"]) ||
      map_path(payload, [:method]) ||
      map_path(payload, ["payload", "method"]) ||
      map_path(payload, [:payload, :method]) ||
      map_path(payload, ["params", "msg", "method"]) ||
      map_path(payload, [:params, :msg, :method])
  end

  defp event_method(_payload), do: nil

  defp agent_message_delta?(method), do: method in ["item/agentMessage/delta", "codex/event/agent_message_delta", "codex/event/agent_message_content_delta"]

  defp agent_message_completed?(method, payload) do
    item_lifecycle_type?(method, payload, "item/completed", "agentMessage")
  end

  defp command_begin?(method, payload) do
    method in ["codex/event/exec_command_begin", "item/commandExecution/begin"] ||
      item_lifecycle_type?(method, payload, "item/started", "commandExecution")
  end

  defp command_output?(method), do: method in ["codex/event/exec_command_output_delta", "item/commandExecution/outputDelta"]

  defp command_end?(method, payload) do
    method in ["codex/event/exec_command_end", "item/commandExecution/end"] ||
      item_lifecycle_type?(method, payload, "item/completed", "commandExecution")
  end

  defp item_lifecycle_type?(method, payload, expected_method, expected_type) do
    method == expected_method and
      (map_path(payload, ["params", "item", "type"]) ||
         map_path(payload, [:params, :item, :type])) == expected_type
  end

  defp manager_steer?(event, message) do
    event[:event] in [:manager_steer_queued, :manager_steer_delivered] or
      (summarize_message(message) || "") =~ "manager steer"
  end

  defp warning_or_error?(event, message) do
    event_name = event[:event] |> to_string() |> String.downcase()
    text = (summarize_message(message) || "") |> String.downcase()
    String.contains?(event_name, ["error", "warning", "failed"]) or String.contains?(text, ["error", "warning", "failed"])
  end

  defp item_key(event, payload) do
    map_path(payload, ["params", "itemId"]) ||
      map_path(payload, [:params, :itemId]) ||
      map_path(payload, ["params", "item", "id"]) ||
      map_path(payload, [:params, :item, :id]) ||
      event[:turn_id] ||
      event[:thread_id] ||
      iso8601(event[:timestamp]) ||
      "event"
  end

  defp extract_completed_agent_text(payload) do
    first_map_path(payload, [
      ["params", "item", "text"],
      [:params, :item, :text],
      ["params", "item", "content"],
      [:params, :item, :content],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "msg", "content"],
      [:params, :msg, :content]
    ])
    |> normalize_agent_text()
  end

  defp normalize_agent_text(text) when is_binary(text), do: text

  defp normalize_agent_text(parts) when is_list(parts) do
    parts
    |> Enum.map(&normalize_agent_text_part/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp normalize_agent_text(_text), do: ""

  defp normalize_agent_text_part(part) when is_binary(part), do: part

  defp normalize_agent_text_part(%{} = part) do
    map_value(part, ["text", :text, "content", :content]) |> normalize_agent_text()
  end

  defp normalize_agent_text_part(_part), do: ""

  defp truncate_text(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      {String.slice(text, 0, limit), true}
    else
      {text, false}
    end
  end

  defp inspect_bounded(value, limit) do
    {bounded, structurally_truncated?} = bound_debug_value(value, limit)

    {excerpt, text_truncated?} =
      bounded
      |> inspect(pretty: true, limit: 50, printable_limit: limit)
      |> truncate_text(limit)

    {excerpt, structurally_truncated? or text_truncated?}
  end

  defp bound_debug_value(value, limit, key \\ nil)

  defp bound_debug_value(value, limit, key) when is_atom(key) and not is_nil(key),
    do: bound_debug_value(value, limit, Atom.to_string(key))

  defp bound_debug_value(value, limit, key) when is_binary(key) do
    if Regex.match?(@debug_sensitive_key_pattern, key) do
      {"[REDACTED]", false}
    else
      bound_debug_value(value, limit, nil)
    end
  end

  defp bound_debug_value(value, limit, nil) when is_binary(value) do
    {excerpt, truncated?} = truncate_text(value, limit)
    {redacted_excerpt, redaction_truncated?} = excerpt |> redact_bounded_string() |> truncate_text(limit)
    {redacted_excerpt, truncated? or redaction_truncated?}
  end

  defp bound_debug_value(value, limit, _key) when is_list(value) do
    {items, truncated?} = take_with_truncation(value, @raw_items_per_display_item)

    {bounded_items, child_truncated?} =
      items
      |> Enum.map(&bound_debug_value(&1, limit))
      |> unzip_bounded_values()

    {bounded_items, truncated? or child_truncated?}
  end

  defp bound_debug_value(value, limit, _key) when is_map(value) do
    {items, truncated?} = take_with_truncation(value, 50)

    {bounded_items, child_truncated?} =
      items
      |> Enum.map(fn {key, item} ->
        {bounded_item, item_truncated?} = bound_debug_value(item, limit, key)
        {{key, bounded_item}, item_truncated?}
      end)
      |> unzip_bounded_values()

    {Map.new(bounded_items), truncated? or child_truncated?}
  end

  defp bound_debug_value(value, _limit, _key), do: {Redactor.redact(value), false}

  defp redact_bounded_string(value) do
    value
    |> Redactor.redact()
    |> then(&Regex.replace(@debug_open_json_secret_field_pattern, &1, "\\1[REDACTED]"))
    |> then(&Regex.replace(@debug_open_assignment_pattern, &1, "\\1=[REDACTED]"))
  end

  defp take_with_truncation(values, limit) do
    values
    |> Enum.reduce_while({[], 0, false}, fn value, {items, count, _truncated?} ->
      if count < limit do
        {:cont, {[value | items], count + 1, false}}
      else
        {:halt, {items, count, true}}
      end
    end)
    |> then(fn {items, _count, truncated?} -> {Enum.reverse(items), truncated?} end)
  end

  defp unzip_bounded_values(values) do
    {
      Enum.map(values, fn {value, _truncated?} -> value end),
      Enum.any?(values, fn {_value, truncated?} -> truncated? end)
    }
  end

  defp first_map_path(value, paths) do
    Enum.find_value(paths, &map_path(value, &1))
  end

  defp map_path(value, path), do: Enum.reduce_while(path, value, &map_path_step/2)

  defp map_path_step(key, %{} = value) do
    case Map.fetch(value, key) do
      {:ok, next} -> {:cont, next}
      :error -> {:halt, nil}
    end
  end

  defp map_path_step(_key, _value), do: {:halt, nil}

  defp map_value(%{} = map, keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: message |> Redactor.redact() |> StatusDashboard.humanize_codex_message()

  defp command_watchdog_payload(nil), do: nil

  defp command_watchdog_payload(watchdog) when is_map(watchdog) do
    %{
      command: Map.get(watchdog, :command),
      status: Map.get(watchdog, :status),
      classification: Map.get(watchdog, :classification),
      classification_reason: Map.get(watchdog, :classification_reason),
      age_ms: Map.get(watchdog, :age_ms),
      idle_ms: Map.get(watchdog, :idle_ms),
      repeated_output_count: Map.get(watchdog, :repeated_output_count),
      started_at: iso8601(Map.get(watchdog, :started_at)),
      last_output_at: iso8601(Map.get(watchdog, :last_output_at)),
      last_progress_at: iso8601(Map.get(watchdog, :last_progress_at))
    }
  end

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
