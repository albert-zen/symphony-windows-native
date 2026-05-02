defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, Redactor, StatusDashboard}

  @conversation_display_limit 120
  @text_excerpt_chars 2_000
  @raw_excerpt_chars 1_500
  @raw_items_per_display_item 8

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
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
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

  @spec worker_conversation([map()]) :: [map()]
  def worker_conversation(events) when is_list(events) do
    events
    |> Enum.reduce([], &append_conversation_event/2)
    |> Enum.reverse()
    |> Enum.take(-@conversation_display_limit)
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      title: issue_title(running),
      url: issue_url(running),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
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
  defp optional_conversation(running), do: running |> Map.get(:recent_codex_events, []) |> worker_conversation()

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

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
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
    Redactor.redact(event[:raw] || event[:message])
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
      agent_message_delta?(method) -> :assistant_delta
      command_begin?(method, payload) -> :command_begin
      command_output?(method) -> :command_output
      command_end?(method, payload) -> :command_end
      manager_steer?(event, message) -> :manager_steer
      warning_or_error?(event, message) -> :warning
      true -> :system
    end
  end

  defp append_classified_conversation_event(:assistant_delta, event, method, payload, _raw, _message, items) do
    append_assistant_delta(event, method, payload, items)
  end

  defp append_classified_conversation_event(:command_begin, event, method, payload, _raw, _message, items) do
    append_command_begin(event, method, payload, items)
  end

  defp append_classified_conversation_event(:command_output, event, _method, payload, _raw, _message, items) do
    append_command_output(event, payload, items)
  end

  defp append_classified_conversation_event(:command_end, event, _method, payload, _raw, _message, items) do
    append_command_end(event, payload, items)
  end

  defp append_classified_conversation_event(:manager_steer, event, _method, _payload, raw, message, items) do
    append_new_item(manager_message_item(event, message, raw), items)
  end

  defp append_classified_conversation_event(:warning, event, _method, _payload, raw, message, items) do
    append_system_item(event, "warning", summarized_event_message(event, message), raw, items)
  end

  defp append_classified_conversation_event(:system, event, _method, _payload, raw, message, items) do
    append_system_item(event, "system", summarized_event_message(event, message), raw, items)
  end

  defp append_assistant_delta(event, method, payload, []) do
    delta = extract_text_delta(payload)
    {excerpt, truncated?} = truncate_text(delta, @text_excerpt_chars)

    append_new_item(
      %{
        type: "assistant",
        key: item_key(event, payload),
        at: iso8601(event[:timestamp]),
        title: "Assistant",
        excerpt: excerpt <> if(truncated?, do: "\n[truncated]", else: ""),
        truncated?: truncated?,
        raw: [raw_item(method, event, payload)]
      },
      []
    )
  end

  defp append_assistant_delta(event, method, payload, [last | rest] = items) do
    key = item_key(event, payload)
    delta = extract_text_delta(payload)

    if last[:type] == "assistant" and last[:key] == key do
      updated =
        last
        |> append_excerpt_delta(delta)
        |> prepend_raw(raw_item(method, event, payload))

      [updated | rest]
    else
      {excerpt, truncated?} = truncate_text(delta, @text_excerpt_chars)

      append_new_item(
        %{
          type: "assistant",
          key: key,
          at: iso8601(event[:timestamp]),
          title: "Assistant",
          excerpt: excerpt <> if(truncated?, do: "\n[truncated]", else: ""),
          truncated?: truncated?,
          raw: [raw_item(method, event, payload)]
        },
        items
      )
    end
  end

  defp append_assistant_delta(event, method, payload, items) do
    append_assistant_delta(event, method, payload, List.wrap(items))
  end

  defp append_command_begin(event, method, payload, items) do
    command = extract_command(payload) || summarize_message(payload) || "command"
    key = item_key(event, payload)

    append_new_item(
      %{
        type: "tool",
        key: key,
        at: iso8601(event[:timestamp]),
        title: "Command",
        command: command,
        status: "running",
        elapsed_ms: nil,
        output_excerpt: "",
        output_truncated?: false,
        raw: [raw_item(method, event, payload)]
      },
      items
    )
  end

  defp append_command_output(event, payload, items) do
    output = extract_command_output(payload)
    key = item_key(event, payload)

    update_matching_or_append_tool(items, key, fn item ->
      output_text = Map.get(item, :output_excerpt, "") <> output
      {excerpt, truncated?} = truncate_text(output_text, @text_excerpt_chars)

      item
      |> Map.put(:output_excerpt, excerpt)
      |> Map.put(:output_truncated?, Map.get(item, :output_truncated?, false) or truncated?)
      |> prepend_raw(raw_item("command output", event, payload))
    end)
  end

  defp append_command_end(event, payload, items) do
    key = item_key(event, payload)
    status = command_status(payload)

    update_matching_or_append_tool(items, key, fn item ->
      item
      |> Map.put(:status, status)
      |> Map.put(:elapsed_ms, elapsed_ms(item.at, event[:timestamp]))
      |> prepend_raw(raw_item("command end", event, payload))
    end)
  end

  defp update_matching_or_append_tool(items, key, fun) do
    case Enum.split_while(items, fn item -> !(item[:type] == "tool" and item[:key] == key) end) do
      {before, [item | after_items]} ->
        before ++ [fun.(item) | after_items]

      _ ->
        placeholder = %{
          type: "tool",
          key: key,
          at: nil,
          title: "Command",
          command: "command",
          status: "running",
          elapsed_ms: nil,
          output_excerpt: "",
          output_truncated?: false,
          raw: []
        }

        append_new_item(fun.(placeholder), items)
    end
  end

  defp append_system_item(event, kind, message, raw, items) do
    append_new_item(
      %{
        type: kind,
        key: "#{kind}:#{iso8601(event[:timestamp])}:#{event[:event]}:#{length(items)}",
        at: iso8601(event[:timestamp]),
        title: if(kind == "warning", do: "Warning", else: event_label(event[:event])),
        excerpt: message || "Worker update",
        raw: [raw_item(event[:event], event, raw)]
      },
      items
    )
  end

  defp append_new_item(item, items), do: [item | items]

  defp display_event_payload(event) do
    cond do
      is_map(event[:message]) -> Redactor.redact(event[:message])
      is_map(event[:raw]) -> raw_event_payload(event)
      true -> Redactor.redact(event[:message])
    end
  end

  defp prepend_raw(item, raw) do
    Map.update(item, :raw, [raw], fn entries ->
      [raw | entries] |> Enum.take(@raw_items_per_display_item)
    end)
  end

  defp append_excerpt_delta(item, delta) do
    current_excerpt =
      item
      |> Map.get(:excerpt, "")
      |> String.replace_suffix("\n[truncated]", "")

    {excerpt, truncated?} = truncate_text(current_excerpt <> delta, @text_excerpt_chars)

    item
    |> Map.put(:excerpt, excerpt <> if(truncated?, do: "\n[truncated]", else: ""))
    |> Map.put(:truncated?, Map.get(item, :truncated?, false) or truncated?)
  end

  defp manager_message_item(event, message, raw) do
    text =
      message
      |> summarize_message()
      |> strip_manager_prefix()

    %{
      type: "user",
      key: "manager:#{iso8601(event[:timestamp])}:#{event[:turn_id]}",
      at: iso8601(event[:timestamp]),
      title: "Manager",
      excerpt: text,
      raw: [raw_item(event[:event], event, raw)]
    }
  end

  defp raw_item(label, event, payload) do
    {excerpt, truncated?} = inspect_bounded(payload, @raw_excerpt_chars)

    %{
      label: to_string(label || event[:event] || "event"),
      at: iso8601(event[:timestamp]),
      excerpt: excerpt,
      truncated?: truncated?
    }
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

  defp summarized_event_message(event, message) do
    summarize_message(event[:message] || message || event[:raw])
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

  defp extract_text_delta(payload) do
    first_map_path(payload, [
      ["params", "delta"],
      [:params, :delta],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta],
      ["params", "msg", "content"],
      [:params, :msg, :content],
      ["params", "msg", "payload", "content"],
      [:params, :msg, :payload, :content]
    ]) ||
      ""
  end

  defp extract_command_output(payload) do
    map_path(payload, ["params", "outputDelta"]) ||
      map_path(payload, [:params, :outputDelta]) ||
      map_path(payload, ["params", "msg", "delta"]) ||
      map_path(payload, [:params, :msg, :delta]) ||
      map_path(payload, ["params", "delta"]) ||
      map_path(payload, [:params, :delta]) ||
      ""
  end

  defp extract_command(payload) do
    command =
      first_map_path(payload, [
        ["params", "msg", "command"],
        [:params, :msg, :command],
        ["params", "item", "command"],
        [:params, :item, :command],
        ["params", "item", "parsedCmd"],
        [:params, :item, :parsedCmd],
        ["params", "item", "parsed_cmd"],
        [:params, :item, :parsed_cmd],
        ["params", "command"],
        [:params, :command],
        ["params", "parsedCmd"],
        [:params, :parsedCmd],
        ["params", "parsed_cmd"],
        [:params, :parsed_cmd]
      ])

    normalize_command(command)
  end

  defp command_status(payload) do
    exit_code =
      map_path(payload, ["params", "msg", "exit_code"]) ||
        map_path(payload, [:params, :msg, :exit_code]) ||
        map_path(payload, ["params", "exitCode"]) ||
        map_path(payload, [:params, :exitCode]) ||
        map_path(payload, ["params", "item", "exitCode"]) ||
        map_path(payload, [:params, :item, :exitCode])

    case exit_code do
      0 -> "completed"
      code when is_integer(code) -> "failed (exit #{code})"
      _ -> "completed"
    end
  end

  defp elapsed_ms(nil, _ended_at), do: nil
  defp elapsed_ms(_started_at, nil), do: nil

  defp elapsed_ms(started_at, %DateTime{} = ended_at) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> max(DateTime.diff(ended_at, parsed, :millisecond), 0)
      _ -> nil
    end
  end

  defp elapsed_ms(_started_at, _ended_at), do: nil

  defp strip_manager_prefix(nil), do: nil

  defp strip_manager_prefix(text) when is_binary(text) do
    text
    |> String.replace_prefix("manager steer queued: ", "")
    |> String.replace_prefix("manager steer delivered: ", "")
  end

  defp normalize_command(%{} = command) do
    binary_command = map_value(command, ["parsedCmd", :parsedCmd, "command", :command, "cmd", :cmd])
    args = map_value(command, ["args", :args, "argv", :argv])

    if is_binary(binary_command) and is_list(args) do
      normalize_command([binary_command | args])
    else
      normalize_command(binary_command || args)
    end
  end

  defp normalize_command(command) when is_binary(command), do: String.trim(command)

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command |> Enum.join(" ") |> normalize_command()
    end
  end

  defp normalize_command(_command), do: nil

  defp truncate_text(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      {String.slice(text, 0, limit), true}
    else
      {text, false}
    end
  end

  defp truncate_text(value, limit), do: value |> to_string() |> truncate_text(limit)

  defp inspect_bounded(value, limit) do
    {bounded, structurally_truncated?} = bound_debug_value(value, limit)
    {excerpt, text_truncated?} = bounded |> inspect(pretty: true, limit: 50, printable_limit: limit) |> truncate_text(limit)

    {excerpt, structurally_truncated? or text_truncated?}
  end

  defp bound_debug_value(value, limit) when is_binary(value) do
    value
    |> Redactor.redact()
    |> truncate_text(limit)
  end

  defp bound_debug_value(value, limit) when is_list(value) do
    {items, truncated?} = take_with_truncation(value, @raw_items_per_display_item)

    {bounded_items, child_truncated?} =
      items
      |> Enum.map(&bound_debug_value(&1, limit))
      |> unzip_bounded_values()

    {bounded_items, truncated? or child_truncated?}
  end

  defp bound_debug_value(value, limit) when is_map(value) do
    {items, truncated?} = value |> Enum.to_list() |> take_with_truncation(50)

    {bounded_items, child_truncated?} =
      items
      |> Enum.map(fn {key, item} ->
        {bounded_item, item_truncated?} = bound_debug_value(item, limit)
        {{key, bounded_item}, item_truncated?}
      end)
      |> unzip_bounded_values()

    {Map.new(bounded_items), truncated? or child_truncated?}
  end

  defp bound_debug_value(value, _limit), do: {Redactor.redact(value), false}

  defp take_with_truncation(values, limit) do
    {Enum.take(values, limit), length(values) > limit}
  end

  defp unzip_bounded_values(values) do
    {
      Enum.map(values, fn {value, _truncated?} -> value end),
      Enum.any?(values, fn {_value, truncated?} -> truncated? end)
    }
  end

  defp event_label(event) when is_atom(event), do: event |> Atom.to_string() |> String.replace("_", " ")
  defp event_label(event), do: event |> to_string() |> String.replace("_", " ")

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
