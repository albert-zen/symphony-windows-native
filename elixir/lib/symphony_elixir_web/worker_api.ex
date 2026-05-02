defmodule SymphonyElixirWeb.WorkerApi do
  @moduledoc """
  Agent-facing worker observability projections.
  """

  alias SymphonyElixir.{Config, Orchestrator, PathSafety, Redactor, StatusDashboard}

  @default_timeline_limit 100
  @max_timeline_limit 200
  @default_debug_limit 50
  @max_debug_limit 200
  @default_body_bytes 4_000
  @debug_value_depth 4
  @debug_collection_limit 20
  @debug_string_bytes 4_000
  @default_patch_bytes 65_536
  @max_patch_bytes 1_048_576

  @spec status_payload(String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :worker_not_found}
  def status_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    with {:ok, _snapshot, running, retry} <- worker_entries(issue_identifier, orchestrator, snapshot_timeout_ms) do
      {:ok, status_body(issue_identifier, running, retry)}
    end
  end

  @spec timeline_payload(String.t(), map(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :worker_not_found}
  def timeline_payload(issue_identifier, params, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) and is_map(params) do
    with {:ok, _snapshot, running, retry} <- worker_entries(issue_identifier, orchestrator, snapshot_timeout_ms) do
      limit = bounded_integer(params["limit"], @default_timeline_limit, @max_timeline_limit)
      before_cursor = parse_cursor(params["before"])

      all_items =
        running
        |> events_for_running()
        |> coalesced_timeline_items(issue_identifier)

      page_items =
        all_items
        |> maybe_before(before_cursor)
        |> Enum.take(limit)

      {:ok,
       %{
         issue_identifier: issue_identifier,
         status: worker_status(running, retry),
         items: Enum.map(page_items, &Map.delete(&1, :coalesce_key)),
         next_before: next_before(page_items, all_items),
         limit: limit
       }}
    end
  end

  @spec debug_events_payload(String.t(), map(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :worker_not_found}
  def debug_events_payload(issue_identifier, params, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) and is_map(params) do
    with {:ok, _snapshot, running, retry} <- worker_entries(issue_identifier, orchestrator, snapshot_timeout_ms) do
      limit = bounded_integer(params["limit"], @default_debug_limit, @max_debug_limit)

      events =
        running
        |> events_for_running()
        |> Enum.reverse()
        |> Enum.take(limit)
        |> Enum.map(&debug_event_payload/1)

      {:ok,
       %{
         issue_identifier: issue_identifier,
         status: worker_status(running, retry),
         events: events,
         limit: limit,
         debug_only: true
       }}
    end
  end

  @spec diff_payload(String.t(), map(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, atom()}
  def diff_payload(issue_identifier, params, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) and is_map(params) do
    with {:ok, _snapshot, running, retry} <- worker_entries(issue_identifier, orchestrator, snapshot_timeout_ms),
         {:ok, workspace_path} <- worker_workspace(issue_identifier, running, retry),
         :ok <- workspace_under_root?(workspace_path),
         :ok <- workspace_directory?(workspace_path),
         :ok <- git_repo?(workspace_path),
         {:ok, changed_files, untracked_files} <- changed_files(workspace_path) do
      diff_body(issue_identifier, workspace_path, changed_files, untracked_files, params)
    end
  end

  defp worker_entries(issue_identifier, orchestrator, snapshot_timeout_ms) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :worker_not_found}
        else
          {:ok, snapshot, running, retry}
        end

      _ ->
        {:error, :worker_not_found}
    end
  end

  defp status_body(issue_identifier, running, retry) do
    %{
      issue: issue_summary(issue_identifier, running, retry),
      status: worker_status(running, retry),
      session: session_summary(running, retry),
      workspace: workspace_summary(issue_identifier, running, retry),
      pull_request: nil,
      checks: nil,
      rate_limits: rate_limit_summary(running),
      tokens: token_summary(running),
      command_watchdog: command_watchdog_payload(Map.get(running || %{}, :command_watchdog)),
      retry: retry_payload(retry),
      last_event: last_event_summary(running)
    }
  end

  defp issue_summary(issue_identifier, running, retry) do
    %{
      id: entry_value(running, retry, :issue_id),
      identifier: issue_identifier,
      title: entry_value(running, retry, :title),
      state: entry_value(running, retry, :state),
      url: entry_value(running, retry, :url)
    }
  end

  defp session_summary(running, retry) do
    %{
      session_id: entry_value(running, retry, :session_id),
      thread_id: entry_value(running, retry, :thread_id),
      turn_id: entry_value(running, retry, :turn_id),
      turn_count: Map.get(running || %{}, :turn_count, 0)
    }
  end

  defp workspace_summary(issue_identifier, running, retry) do
    %{
      path: workspace_path(issue_identifier, running, retry),
      host: entry_value(running, retry, :worker_host),
      branch: entry_value(running, retry, :branch_name)
    }
  end

  defp rate_limit_summary(running) do
    %{
      worker: redacted_value(Map.get(running || %{}, :codex_rate_limits)),
      worker_updated_at: iso8601(Map.get(running || %{}, :codex_rate_limits_updated_at))
    }
  end

  defp token_summary(running) do
    %{
      input_tokens: Map.get(running || %{}, :codex_input_tokens, 0),
      output_tokens: Map.get(running || %{}, :codex_output_tokens, 0),
      total_tokens: Map.get(running || %{}, :codex_total_tokens, 0)
    }
  end

  defp last_event_summary(running) do
    %{
      event: stringify(Map.get(running || %{}, :last_codex_event)),
      at: iso8601(Map.get(running || %{}, :last_codex_timestamp)),
      message: summarize_message(Map.get(running || %{}, :last_codex_message))
    }
  end

  defp events_for_running(nil), do: []
  defp events_for_running(running), do: Map.get(running, :recent_codex_events, [])

  defp coalesced_timeline_items(events, issue_identifier) do
    events
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {event, sequence}, acc ->
      item = timeline_item(event, issue_identifier, sequence)
      append_timeline_item(acc, item)
    end)
  end

  defp append_timeline_item([], item), do: [item]

  defp append_timeline_item([previous | rest], %{coalesce_key: key} = item)
       when not is_nil(key) do
    if previous.coalesce_key == key do
      merged = merge_timeline_items(previous, item)
      [merged | rest]
    else
      [item, previous | rest]
    end
  end

  defp append_timeline_item(acc, item), do: [item | acc]

  defp merge_timeline_items(previous, item) do
    body = Redactor.redact(previous.body <> item.body)
    truncated = previous.truncated or item.truncated or byte_size(body) > @default_body_bytes

    previous
    |> Map.put(:body, body |> truncate_text(@default_body_bytes) |> Map.fetch!(:text))
    |> Map.put(:truncated, truncated)
    |> Map.put(:updated_at, item.created_at)
    |> Map.put(:cursor, item.cursor)
    |> Map.put(:id, item.id)
  end

  defp timeline_item(event, issue_identifier, sequence) do
    normalized = normalize_event(event)
    type = timeline_type(normalized)
    body = timeline_body(normalized, type)
    truncated_body = truncate_text(body, @default_body_bytes)
    cursor = Integer.to_string(sequence)

    %{
      id: timeline_id(issue_identifier, sequence, type, body),
      cursor: cursor,
      type: type,
      created_at: iso8601(event[:timestamp]),
      updated_at: nil,
      source: source_payload(event, normalized),
      body: truncated_body.text,
      truncated: truncated_body.truncated,
      metadata: timeline_metadata(normalized),
      coalesce_key: coalesce_key(normalized, type)
    }
  end

  defp normalize_event(event) when is_map(event) do
    raw = decode_json(event[:raw])
    message = decode_json(event[:message])
    payload = first_map([raw, message, event[:payload], event[:message], event[:raw]]) || %{}
    method = map_path(payload, ["method"]) || map_path(payload, [:method])

    %{
      event: event[:event],
      method: method,
      payload: payload,
      message: event[:message],
      raw: event[:raw]
    }
  end

  defp timeline_type(%{event: event}) when event in [:manager_steer_queued, :manager_steer_submitted, :manager_steer_delivered],
    do: "manager_steer"

  defp timeline_type(%{event: event}) when event in [:manager_steer_rejected, :manager_steer_failed],
    do: "error"

  defp timeline_type(%{event: event}) when event in [:tool_call_completed, :tool_call_failed, :unsupported_tool_call],
    do: "tool_call"

  defp timeline_type(%{method: method}) when method in ["item/agentMessage/delta", "item/reasoning/textDelta"],
    do: "assistant_message"

  defp timeline_type(%{method: method})
       when method in ["item/commandExecution/outputDelta", "item/fileChange/outputDelta"],
       do: "tool_output"

  defp timeline_type(%{method: method})
       when method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/call"],
       do: "tool_call"

  defp timeline_type(%{method: method}) when method in ["turn/failed", "turn/cancelled"], do: "error"

  defp timeline_type(%{method: method})
       when method in ["thread/started", "turn/started", "turn/completed", "turn/diff/updated", "turn/plan/updated"],
       do: "state_change"

  defp timeline_type(_normalized), do: "system_warning"

  defp timeline_body(normalized, type) when type in ["assistant_message", "tool_output"] do
    case streaming_text(normalized.payload) do
      text when is_binary(text) -> Redactor.redact(text)
      _ -> summarize_normalized(normalized)
    end
  end

  defp timeline_body(normalized, "manager_steer") do
    normalized.message
    |> raw_text()
    |> case do
      "" -> summarize_normalized(normalized)
      text -> text
    end
  end

  defp timeline_body(normalized, _type), do: summarize_normalized(normalized)

  defp summarize_normalized(normalized) do
    %{event: normalized.event, message: normalized.message || normalized.payload || normalized.raw}
    |> summarize_message()
    |> Kernel.||("")
  end

  defp source_payload(event, normalized) do
    %{
      event: stringify(event[:event]),
      method: normalized.method,
      session_id: event[:session_id],
      thread_id: event[:thread_id],
      turn_id: event[:turn_id]
    }
  end

  defp timeline_metadata(%{payload: payload}) do
    %{
      item_id: map_path(payload, ["params", "item", "id"]) || map_path(payload, [:params, :item, :id]),
      tool: map_path(payload, ["params", "tool"]) || map_path(payload, [:params, :tool]),
      command:
        map_path(payload, ["params", "parsedCmd"]) ||
          map_path(payload, [:params, :parsedCmd]) ||
          map_path(payload, ["params", "command"]) ||
          map_path(payload, [:params, :command])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> redacted_value()
  end

  defp coalesce_key(%{payload: payload}, type) when type in ["assistant_message", "tool_output"] do
    item_id = map_path(payload, ["params", "itemId"]) || map_path(payload, [:params, :itemId])
    {type, item_id}
  end

  defp coalesce_key(_normalized, _type), do: nil

  defp maybe_before(items, nil), do: items
  defp maybe_before(items, before_sequence), do: Enum.filter(items, &(cursor_sequence(&1.cursor) < before_sequence))

  defp next_before([], _all_items), do: nil

  defp next_before(page_items, all_items) do
    last_sequence = page_items |> List.last() |> Map.fetch!(:cursor) |> cursor_sequence()

    if Enum.any?(all_items, &(cursor_sequence(&1.cursor) < last_sequence)) do
      Integer.to_string(last_sequence)
    else
      nil
    end
  end

  defp debug_event_payload(event) do
    redacted = redacted_value(event)

    %{
      at: iso8601(redacted[:timestamp]),
      event: stringify(redacted[:event]),
      session_id: redacted[:session_id],
      thread_id: redacted[:thread_id],
      turn_id: redacted[:turn_id],
      message: truncate_value(redacted[:message]),
      raw: truncate_value(redacted[:raw]),
      payload: truncate_value(redacted[:payload])
    }
  end

  defp worker_workspace(issue_identifier, running, retry) do
    path = workspace_path(issue_identifier, running, retry)

    if is_binary(path) and String.trim(path) != "" do
      {:ok, path}
    else
      {:error, :workspace_missing}
    end
  end

  defp workspace_under_root?(workspace_path) do
    root = Config.settings!().workspace.root

    with {:ok, canonical_root} <- PathSafety.canonicalize(root),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace_path) do
      if under_path?(canonical_workspace, canonical_root) do
        :ok
      else
        {:error, :workspace_outside_root}
      end
    end
  end

  defp workspace_directory?(workspace_path) do
    if File.dir?(workspace_path), do: :ok, else: {:error, :workspace_missing}
  end

  defp git_repo?(workspace_path) do
    case git_output(workspace_path, ["rev-parse", "--is-inside-work-tree"]) do
      {:ok, output} when output in ["true\n", "true\r\n"] -> :ok
      _ -> {:error, :not_git_repo}
    end
  end

  defp changed_files(workspace_path) do
    with {:ok, output} <- git_output(workspace_path, ["status", "--porcelain=v1"]) do
      {tracked_files, untracked_files} =
        output
        |> String.split(["\r\n", "\n"], trim: true)
        |> Enum.map(&status_file/1)
        |> Enum.split_with(fn {status, _file} -> status != "??" end)

      files =
        (tracked_files ++ untracked_files)
        |> Enum.map(fn {_status, file} -> Redactor.redact(file) end)

      untracked =
        untracked_files
        |> Enum.map(fn {_status, file} -> file end)

      {:ok, files, untracked}
    end
  end

  defp status_file(line) do
    status = String.slice(line, 0, 2)

    file =
      line
      |> String.slice(3..-1//1)
      |> String.replace(~r/^.* -> /, "")

    {status, file}
  end

  defp diff_body(issue_identifier, workspace_path, [], _untracked_files, _params) do
    {:ok, no_diff_body(issue_identifier, workspace_path)}
  end

  defp diff_body(issue_identifier, workspace_path, changed_files, untracked_files, params) do
    format = diff_format(params["format"])
    limit_bytes = bounded_integer(params["limit_bytes"], @default_patch_bytes, @max_patch_bytes)

    with {:ok, stat} <- diff_stat(workspace_path, untracked_files),
         {:ok, patch} <- maybe_patch(workspace_path, format, limit_bytes, untracked_files) do
      {:ok,
       %{
         issue_identifier: issue_identifier,
         workspace: %{path: workspace_path},
         changed_files: changed_files,
         stat: truncate_text(stat, @default_body_bytes),
         patch: patch,
         format: format,
         empty: false
       }}
    end
  end

  defp diff_stat(workspace_path, untracked_files) do
    with {:ok, tracked_stat} <- git_output(workspace_path, ["diff", "HEAD", "--stat", "--"]) do
      untracked_stat =
        untracked_files
        |> Enum.map_join("", &untracked_file_stat(workspace_path, &1))

      {:ok, tracked_stat <> untracked_stat}
    end
  end

  defp untracked_file_stat(workspace_path, relative_path) do
    redacted_path = Redactor.redact(relative_path)

    case untracked_entry(workspace_path, relative_path) do
      {:ok, _path, %{type: :regular, size: size}} ->
        " #{redacted_path} | #{size} bytes\n"

      {:ok, _path, %{type: type}} ->
        " #{redacted_path} | #{type}\n"
    end
  end

  defp maybe_patch(_workspace_path, "stat", _limit_bytes, _untracked_files), do: {:ok, nil}

  defp maybe_patch(workspace_path, "patch", limit_bytes, untracked_files) do
    with {:ok, output} <- git_output(workspace_path, ["diff", "HEAD", "--"]) do
      remaining_bytes = max(limit_bytes - byte_size(output), 0)
      patch = output <> untracked_patch(workspace_path, untracked_files, remaining_bytes)
      {:ok, truncate_text(patch, limit_bytes)}
    end
  end

  defp untracked_patch(workspace_path, untracked_files, limit_bytes) do
    untracked_files
    |> Enum.reduce_while({"", limit_bytes}, fn relative_path, {patch, remaining_bytes} ->
      if remaining_bytes <= 0 do
        {:halt, {patch, remaining_bytes}}
      else
        next_patch = untracked_file_patch(workspace_path, relative_path, remaining_bytes)
        combined = patch <> next_patch
        {:cont, {combined, max(limit_bytes - byte_size(combined), 0)}}
      end
    end)
    |> elem(0)
  end

  defp untracked_file_patch(workspace_path, relative_path, limit_bytes) do
    redacted_path = Redactor.redact(relative_path)

    case untracked_entry(workspace_path, relative_path) do
      {:ok, path, %{type: :regular}} ->
        content = read_untracked_patch_content(path, limit_bytes)
        redacted_content = content |> printable_patch_content() |> Redactor.redact()
        line_count = redacted_content |> String.split(["\r\n", "\n"]) |> length()

        [
          "diff --git a/#{redacted_path} b/#{redacted_path}\n",
          "new file mode 100644\n",
          "--- /dev/null\n",
          "+++ b/#{redacted_path}\n",
          "@@ -0,0 +#{line_count} @@\n",
          redacted_content
          |> truncate_text(limit_bytes)
          |> Map.fetch!(:text)
          |> String.split(["\r\n", "\n"], trim: false)
          |> Enum.map_join("\n", &"+#{&1}"),
          "\n"
        ]
        |> IO.iodata_to_binary()

      {:ok, _path, %{type: type}} ->
        "diff --git a/#{redacted_path} b/#{redacted_path}\n# untracked #{type} omitted\n"
    end
  end

  defp read_untracked_patch_content(path, limit_bytes) do
    file = File.open!(path, [:read, :binary])

    try do
      IO.binread(file, limit_bytes + 1)
    after
      File.close(file)
    end
  end

  defp printable_patch_content(content) do
    if String.valid?(content) do
      content
    else
      "[binary content omitted]\n"
    end
  end

  defp untracked_entry(workspace_path, relative_path) do
    workspace = Path.expand(workspace_path)
    path = Path.expand(relative_path, workspace)

    true = under_path?(path, workspace)
    {:ok, stat} = File.lstat(path)
    {:ok, path, stat}
  end

  defp git_output(workspace_path, args) do
    case System.cmd("git", ["-C", workspace_path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, Redactor.redact(output)}
      {_output, _status} -> {:error, :git_failed}
    end
  end

  defp no_diff_body(issue_identifier, workspace_path) do
    %{
      issue_identifier: issue_identifier,
      workspace: %{path: workspace_path},
      changed_files: [],
      stat: %{text: "", truncated: false, bytes: 0, limit_bytes: @default_body_bytes},
      patch: nil,
      format: "stat",
      empty: true
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    entry_value(running, retry, :workspace_path) || Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp entry_value(running, retry, key), do: Map.get(running || %{}, key) || Map.get(retry || %{}, key)

  defp retry_payload(nil), do: nil

  defp retry_payload(retry) do
    %{
      attempt: Map.get(retry, :attempt),
      due_in_ms: Map.get(retry, :due_in_ms),
      error: redacted_value(Map.get(retry, :error)),
      error_kind: Map.get(retry, :error_kind),
      prior_error: redacted_value(Map.get(retry, :prior_error)),
      prior_error_kind: Map.get(retry, :prior_error_kind)
    }
  end

  defp worker_status(_running, nil), do: "running"
  defp worker_status(nil, _retry), do: "retrying"
  defp worker_status(_running, _retry), do: "running"

  defp command_watchdog_payload(nil), do: nil

  defp command_watchdog_payload(watchdog) when is_map(watchdog) do
    watchdog
    |> Redactor.redact()
    |> Map.take([
      :command,
      :status,
      :classification,
      :classification_reason,
      :age_ms,
      :idle_ms,
      :repeated_output_count,
      :started_at,
      :last_output_at,
      :last_progress_at
    ])
    |> Map.update(:started_at, nil, &iso8601/1)
    |> Map.update(:last_output_at, nil, &iso8601/1)
    |> Map.update(:last_progress_at, nil, &iso8601/1)
  end

  defp bounded_integer(value, default, max) do
    case Integer.parse(to_string(value || "")) do
      {parsed, ""} when parsed > 0 -> min(parsed, max)
      _ -> default
    end
  end

  defp parse_cursor(nil), do: nil
  defp parse_cursor(value), do: cursor_sequence(value)

  defp cursor_sequence(value) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp diff_format("patch"), do: "patch"
  defp diff_format(_format), do: "stat"

  defp truncate_value(nil), do: nil

  defp truncate_value(value) when is_binary(value), do: truncate_text(value, @default_body_bytes)

  defp truncate_value(value) do
    value
    |> bounded_debug_value(@debug_value_depth)
    |> Redactor.redact()
    |> inspect(limit: @debug_collection_limit, printable_limit: @debug_string_bytes)
    |> truncate_text(@default_body_bytes)
  end

  defp bounded_debug_value(value, _depth) when is_binary(value) do
    value
    |> truncate_text(@debug_string_bytes)
    |> Map.fetch!(:text)
  end

  defp bounded_debug_value(value, _depth) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp bounded_debug_value(value, depth) when depth <= 0, do: inspect(value, limit: 3, printable_limit: 120)

  defp bounded_debug_value(value, depth) when is_map(value) do
    value
    |> Enum.take(@debug_collection_limit)
    |> Map.new(fn {key, nested_value} ->
      {bounded_debug_value(key, depth - 1), bounded_debug_value(nested_value, depth - 1)}
    end)
  end

  defp bounded_debug_value(value, depth) when is_list(value) do
    value
    |> Enum.take(@debug_collection_limit)
    |> Enum.map(&bounded_debug_value(&1, depth - 1))
  end

  defp bounded_debug_value(value, _depth), do: inspect(value, limit: 3, printable_limit: 120)

  defp truncate_text(text, limit_bytes) when is_binary(text) do
    bytes = byte_size(text)

    if bytes > limit_bytes do
      %{text: take_bytes(text, limit_bytes), truncated: true, bytes: bytes, limit_bytes: limit_bytes}
    else
      %{text: text, truncated: false, bytes: bytes, limit_bytes: limit_bytes}
    end
  end

  defp raw_text(value) when is_binary(value), do: Redactor.redact(value)
  defp raw_text(value) when is_map(value) or is_list(value), do: value |> Redactor.redact() |> Jason.encode!()
  defp raw_text(_value), do: ""

  defp streaming_text(payload) do
    map_path(payload, ["params", "textDelta"]) ||
      map_path(payload, [:params, :textDelta]) ||
      map_path(payload, ["params", "msg", "textDelta"]) ||
      map_path(payload, [:params, :msg, :textDelta]) ||
      map_path(payload, ["params", "outputDelta"]) ||
      map_path(payload, [:params, :outputDelta]) ||
      map_path(payload, ["params", "msg", "outputDelta"]) ||
      map_path(payload, [:params, :msg, :outputDelta])
  end

  defp summarize_message(nil), do: nil

  defp summarize_message(message) do
    message
    |> Redactor.redact()
    |> StatusDashboard.humanize_codex_message()
  end

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp decode_json(value), do: value

  defp first_map(values) do
    Enum.find(values, &is_map/1)
  end

  defp map_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      map_child(acc, key)
    end)
  end

  defp map_child(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> {:cont, Map.fetch!(map, key)}
      is_atom(key) -> string_key_value(map, Atom.to_string(key))
      is_binary(key) -> atom_key_value(map, key)
    end
  end

  defp map_child(_value, _key), do: {:halt, nil}

  defp string_key_value(map, key) do
    if Map.has_key?(map, key) do
      {:cont, Map.fetch!(map, key)}
    else
      {:halt, nil}
    end
  end

  defp atom_key_value(map, key) do
    case safe_existing_atom(key) do
      {:ok, atom_key} when is_map_key(map, atom_key) -> {:cont, Map.fetch!(map, atom_key)}
      _ -> {:halt, nil}
    end
  end

  defp safe_existing_atom(key), do: {:ok, String.to_existing_atom(key)}

  defp redacted_value(value), do: Redactor.redact(value)

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp timeline_id(issue_identifier, sequence, type, body) do
    hash = :erlang.phash2({issue_identifier, sequence, type, body})
    "#{issue_identifier}:#{sequence}:#{type}:#{hash}"
  end

  defp take_bytes(text, limit_bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, size} ->
      next_size = size + byte_size(grapheme)

      if next_size > limit_bytes do
        {:halt, {acc, size}}
      else
        {:cont, {acc <> grapheme, next_size}}
      end
    end)
    |> elem(0)
  end

  defp under_path?(path, root) do
    relative = Path.relative_to(path, root)
    relative == "." or (relative != path and not String.starts_with?(relative, ".."))
  end
end
