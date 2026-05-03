defmodule SymphonyElixir.WorkflowConfigEditor do
  @moduledoc """
  Safe editor for low-risk fields in the active WORKFLOW.md file.

  The editor intentionally supports a small whitelist. It preserves the prompt
  body and most front-matter text by replacing only the selected scalar/list
  fields instead of re-rendering the whole YAML document.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Workflow, WorkflowStore}

  @hash_bytes 12

  @editable_fields %{
    "agent.max_concurrent_agents" => %{section: "agent", key: "max_concurrent_agents", type: :positive_integer},
    "agent.max_turns" => %{section: "agent", key: "max_turns", type: :positive_integer},
    "polling.interval_ms" => %{section: "polling", key: "interval_ms", type: :positive_integer},
    "codex.turn_timeout_ms" => %{section: "codex", key: "turn_timeout_ms", type: :positive_integer},
    "codex.read_timeout_ms" => %{section: "codex", key: "read_timeout_ms", type: :positive_integer},
    "codex.stall_timeout_ms" => %{section: "codex", key: "stall_timeout_ms", type: :non_negative_integer},
    "codex.command_watchdog_long_running_ms" => %{
      section: "codex",
      key: "command_watchdog_long_running_ms",
      type: :non_negative_integer
    },
    "codex.command_watchdog_idle_ms" => %{section: "codex", key: "command_watchdog_idle_ms", type: :non_negative_integer},
    "codex.command_watchdog_stalled_ms" => %{
      section: "codex",
      key: "command_watchdog_stalled_ms",
      type: :non_negative_integer
    },
    "codex.command_watchdog_repeated_output_limit" => %{
      section: "codex",
      key: "command_watchdog_repeated_output_limit",
      type: :positive_integer
    },
    "observability.refresh_ms" => %{section: "observability", key: "refresh_ms", type: :positive_integer},
    "observability.render_interval_ms" => %{section: "observability", key: "render_interval_ms", type: :positive_integer},
    "tracker.dispatch_states" => %{
      section: "tracker",
      key: "dispatch_states",
      type: :state_list,
      warning: "Dispatch states control which issues Symphony may claim. Review dependencies before applying."
    }
  }

  @field_order @editable_fields |> Map.keys() |> Enum.sort()

  @type preview_result :: %{
          current_hash: String.t(),
          proposed_hash: String.t(),
          changed_fields: [String.t()],
          warnings: [String.t()],
          application_effects: map(),
          diff: String.t(),
          proposed_content: String.t()
        }

  @spec editable_fields() :: [String.t()]
  def editable_fields, do: @field_order

  @spec current_content(keyword()) :: {:ok, String.t()} | {:error, term()}
  def current_content(opts \\ []) do
    opts
    |> Keyword.get(:path, Workflow.workflow_file_path())
    |> File.read()
  end

  @spec workflow_candidates(keyword()) :: [Path.t()]
  def workflow_candidates(opts \\ []) do
    roots =
      opts
      |> Keyword.get_lazy(:roots, &candidate_roots/0)
      |> Enum.reject(&blank?/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()

    roots
    |> Enum.flat_map(&candidate_files/1)
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase/1)
  end

  @spec switch_workflow_path(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def switch_workflow_path(path, opts \\ []) when is_binary(path) do
    active_workers_count = Keyword.get(opts, :active_workers_count, 0)
    expanded_path = Path.expand(String.trim(path))

    with :ok <- ensure_no_active_workers(active_workers_count, [:workflow_path]),
         :ok <- ensure_markdown_file(expanded_path),
         {:ok, workflow} <- Workflow.load(expanded_path),
         {:ok, _settings} <- Schema.parse(workflow.config) do
      :ok = Workflow.set_workflow_file_path(expanded_path)

      {:ok,
       %{
         path: expanded_path,
         hash: expanded_path |> File.read!() |> content_hash(),
         application_effects: %{
           workflow_store: "WorkflowStore reloaded the selected file immediately.",
           future_work: "Future polls and future worker runs now use this workflow path.",
           active_workers: "Path switching is blocked while workers are active.",
           restart_required?: false,
           restart_reasons: [
             "Managed reload uses the current runtime workflow path. External manual restart commands must pass this selected path to keep using it."
           ]
         }
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reveal_path(Path.t(), keyword()) :: :ok | {:error, term()}
  def reveal_path(path, opts \\ []) when is_binary(path) do
    deps = Keyword.get(opts, :deps, %{})
    os_type = Map.get(deps, :os_type, &:os.type/0).()
    find_executable = Map.get(deps, :find_executable, &System.find_executable/1)
    cmd = Map.get(deps, :cmd, &System.cmd/3)
    expanded_path = Path.expand(path)

    case {os_type, find_executable.("explorer.exe")} do
      {{:win32, _}, explorer} when is_binary(explorer) ->
        args =
          if File.exists?(expanded_path) do
            ["/select,#{expanded_path}"]
          else
            [existing_parent(expanded_path)]
          end

        case cmd.(explorer, args, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:explorer_failed, status, output}}
        end

      {{:win32, _}, _} ->
        {:error, :explorer_unavailable}

      {other, _} ->
        {:error, {:unsupported_os, other}}
    end
  end

  @spec preview_content(String.t(), keyword()) :: {:ok, preview_result()} | {:error, term()}
  def preview_content(proposed_content, opts \\ []) when is_binary(proposed_content) do
    path = Keyword.get(opts, :path, Workflow.workflow_file_path())

    with {:ok, current} <- File.read(path),
         :ok <- validate_content(proposed_content) do
      {:ok,
       %{
         current_hash: content_hash(current),
         proposed_hash: content_hash(proposed_content),
         changed_fields: [:full_workflow],
         warnings: [],
         application_effects: application_effects(current, proposed_content),
         diff: diff(current, proposed_content),
         proposed_content: proposed_content
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec apply_content(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_content(proposed_content, opts \\ []) when is_binary(proposed_content) do
    active_workers_count = Keyword.get(opts, :active_workers_count, 0)
    path = Keyword.get(opts, :path, Workflow.workflow_file_path())

    with {:ok, preview} <- preview_content(proposed_content, path: path),
         :ok <- ensure_no_active_workers(active_workers_count, preview.changed_fields),
         {:ok, backup_path} <- write_backup(path),
         :ok <- write_workflow(path, preview.proposed_content),
         :ok <- reload_workflow_store(),
         {:ok, applied} <- File.read(path) do
      {:ok,
       %{
         previous_hash: preview.current_hash,
         proposed_hash: preview.proposed_hash,
         applied_hash: content_hash(applied),
         changed_fields: preview.changed_fields,
         warnings: preview.warnings,
         backup_path: backup_path
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec preview(map(), keyword()) :: {:ok, preview_result()} | {:error, term()}
  def preview(params, opts \\ []) when is_map(params) do
    path = Keyword.get(opts, :path, Workflow.workflow_file_path())

    with {:ok, updates} <- normalize_params(params),
         {:ok, current} <- File.read(path),
         {:ok, proposed, changed_fields} <- propose_content(current, updates),
         :ok <- validate_content(proposed) do
      {:ok,
       %{
         current_hash: content_hash(current),
         proposed_hash: content_hash(proposed),
         changed_fields: changed_fields,
         warnings: warnings_for(changed_fields),
         application_effects: application_effects(current, proposed),
         diff: diff(current, proposed),
         proposed_content: proposed
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec apply(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply(params, opts \\ []) when is_map(params) do
    active_workers_count = Keyword.get(opts, :active_workers_count, 0)
    path = Keyword.get(opts, :path, Workflow.workflow_file_path())

    with {:ok, preview} <- preview(params, path: path),
         :ok <- ensure_no_active_workers(active_workers_count, preview.changed_fields),
         {:ok, backup_path} <- write_backup(path),
         :ok <- write_workflow(path, preview.proposed_content),
         :ok <- reload_workflow_store(),
         {:ok, applied} <- File.read(path) do
      {:ok,
       %{
         previous_hash: preview.current_hash,
         proposed_hash: preview.proposed_hash,
         applied_hash: content_hash(applied),
         changed_fields: preview.changed_fields,
         warnings: preview.warnings,
         backup_path: backup_path
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_params(params) do
    with :ok <- ensure_supported_fields(params) do
      params
      |> Enum.sort_by(fn {field, _value} -> to_string(field) end)
      |> Enum.reduce_while({:ok, []}, &collect_update/2)
      |> case do
        {:ok, updates} -> {:ok, Enum.reverse(updates)}
        error -> error
      end
    end
  end

  defp ensure_supported_fields(params) do
    unsupported =
      params
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&Map.has_key?(@editable_fields, &1))
      |> Enum.sort()

    if unsupported != [] do
      {:error, {:unsupported_fields, unsupported}}
    else
      :ok
    end
  end

  defp collect_update({field, value}, {:ok, updates}) do
    field = to_string(field)
    spec = Map.fetch!(@editable_fields, field)

    case normalize_value(field, value, spec.type) do
      {:ok, normalized} -> {:cont, {:ok, [{field, spec, normalized} | updates]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_value(field, value, :positive_integer), do: normalize_integer(field, value, 1)
  defp normalize_value(field, value, :non_negative_integer), do: normalize_integer(field, value, 0)

  defp normalize_value(field, value, :state_list) do
    states =
      value
      |> to_string()
      |> String.split([",", "\n", "\r"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if states == [] do
      {:error, {:invalid_field, field, "must include at least one state"}}
    else
      {:ok, states}
    end
  end

  defp normalize_integer(field, value, minimum) do
    case Integer.parse(String.trim(to_string(value))) do
      {integer, ""} when integer >= minimum ->
        {:ok, integer}

      _ ->
        message = if minimum == 0, do: "must be a non-negative integer", else: "must be a positive integer"
        {:error, {:invalid_field, field, message}}
    end
  end

  defp propose_content(content, updates) do
    with {:ok, front_lines, prompt_lines} <- split_content(content) do
      {updated_front_lines, changed_fields} =
        Enum.reduce(updates, {front_lines, []}, &apply_update/2)

      proposed = join_content(updated_front_lines, prompt_lines)
      {:ok, proposed, Enum.reverse(changed_fields)}
    end
  end

  defp apply_update({field, spec, value}, {lines, changed_fields}) do
    {updated_lines, changed?} = put_field(lines, spec.section, spec.key, value, spec.type)

    if changed? do
      {updated_lines, [field | changed_fields]}
    else
      {updated_lines, changed_fields}
    end
  end

  defp split_content(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {:ok, front, prompt_lines}
          _ -> {:error, :workflow_front_matter_not_closed}
        end

      _ ->
        {:error, :workflow_front_matter_missing}
    end
  end

  defp join_content(front_lines, prompt_lines), do: Enum.join(["---" | front_lines] ++ ["---" | prompt_lines], "\n")

  defp put_field(lines, section, key, value, type) do
    case section_bounds(lines, section) do
      nil ->
        section_lines = ["#{section}:"] ++ field_lines(key, value, type)
        {lines ++ section_lines, true}

      {start_index, end_index} ->
        put_field_in_section(lines, start_index + 1, end_index, key, value, type)
    end
  end

  defp put_field_in_section(lines, start_index, end_index, key, value, :state_list) do
    replacement = field_lines(key, value, :state_list)

    case field_index(lines, start_index, end_index, key) do
      nil ->
        {List.insert_at(lines, end_index, replacement) |> List.flatten(), true}

      index ->
        stop_index = list_value_stop_index(lines, index + 1, end_index)
        current = Enum.slice(lines, index, stop_index - index)

        if current == replacement do
          {lines, false}
        else
          {replace_range(lines, index, stop_index, replacement), true}
        end
    end
  end

  defp put_field_in_section(lines, start_index, end_index, key, value, type) do
    replacement = field_lines(key, value, type)

    case field_index(lines, start_index, end_index, key) do
      nil ->
        {List.insert_at(lines, end_index, replacement) |> List.flatten(), true}

      index ->
        current = Enum.at(lines, index)

        if [current] == replacement do
          {lines, false}
        else
          {List.replace_at(lines, index, hd(replacement)), true}
        end
    end
  end

  defp section_bounds(lines, section) do
    section_pattern = Regex.compile!("^#{Regex.escape(section)}:\\s*(?:#.*)?$")

    case Enum.find_index(lines, &Regex.match?(section_pattern, &1)) do
      nil ->
        nil

      start_index ->
        end_index =
          lines
          |> Enum.drop(start_index + 1)
          |> Enum.find_index(&top_level_field?/1)
          |> case do
            nil -> length(lines)
            relative -> start_index + 1 + relative
          end

        {start_index, end_index}
    end
  end

  defp top_level_field?(line), do: Regex.match?(~r/^[A-Za-z0-9_-]+:\s*(?:#.*)?$/, line)

  defp field_index(lines, start_index, end_index, key) do
    pattern = Regex.compile!("^\\s{2}#{Regex.escape(key)}:\\s*.*$")

    indexes(start_index, end_index)
    |> Enum.find(fn index -> Regex.match?(pattern, Enum.at(lines, index, "")) end)
  end

  defp list_value_stop_index(lines, index, end_index) do
    indexes(index, end_index)
    |> Enum.find(fn line_index ->
      line = Enum.at(lines, line_index, "")
      not (String.trim(line) == "" or String.starts_with?(line, "    "))
    end) || end_index
  end

  defp indexes(start_index, end_index) when start_index < end_index, do: start_index..(end_index - 1)
  defp indexes(_start_index, _end_index), do: []

  defp field_lines(key, values, :state_list) do
    ["  #{key}:"] ++ Enum.map(values, &"    - #{yaml_scalar(&1)}")
  end

  defp field_lines(key, value, _type), do: ["  #{key}: #{value}"]

  defp yaml_scalar(value) do
    value = to_string(value)

    if Regex.match?(~r/^[A-Za-z0-9_ .-]+$/, value) do
      value
    else
      inspect(value)
    end
  end

  defp replace_range(lines, start_index, stop_index, replacement) do
    Enum.take(lines, start_index) ++ replacement ++ Enum.drop(lines, stop_index)
  end

  defp validate_content(content) do
    with {:ok, workflow} <- Workflow.parse_content(content),
         {:ok, _settings} <- Schema.parse(workflow.config) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_workflow, reason}}
    end
  end

  defp application_effects(current_content, proposed_content) do
    restart_reasons =
      with {:ok, current_settings} <- parse_settings(current_content),
           {:ok, proposed_settings} <- parse_settings(proposed_content) do
        restart_reasons(current_settings, proposed_settings)
      else
        {:error, _reason} -> []
      end

    %{
      workflow_store: "Reloaded immediately after Apply.",
      future_work: "Polling, dispatch, prompt, tracker, Codex, worker, and workspace settings affect future polls and future worker runs.",
      active_workers: "Apply is blocked while workers are active; already-running worker sessions do not receive mid-run prompt/config changes.",
      restart_required?: restart_reasons != [],
      restart_reasons: restart_reasons
    }
  end

  defp parse_settings(content) do
    case Workflow.parse_content(content) do
      {:ok, workflow} -> Schema.parse(workflow.config)
      {:error, reason} -> {:error, reason}
    end
  end

  defp restart_reasons(current, proposed) do
    []
    |> maybe_add_restart_reason(
      current.server.host != proposed.server.host or current.server.port != proposed.server.port,
      "HTTP server host/port changes require a runtime restart to rebind the listener."
    )
    |> maybe_add_restart_reason(
      current.observability.steer_token != proposed.observability.steer_token,
      "Operator steer token changes require a runtime restart because endpoint auth is configured at server start."
    )
    |> maybe_add_restart_reason(
      current.workspace.startup_cleanup_ttl_ms != proposed.workspace.startup_cleanup_ttl_ms,
      "Startup cleanup TTL changes apply to the next startup cleanup run; restart when you want that cleanup policy applied immediately."
    )
    |> Enum.reverse()
  end

  defp maybe_add_restart_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_add_restart_reason(reasons, false, _reason), do: reasons

  defp candidate_roots do
    cwd = File.cwd!()
    workflow_dir = Workflow.workflow_file_path() |> Path.expand() |> Path.dirname()

    [workflow_dir, cwd, Path.dirname(cwd)]
  end

  defp candidate_files(root) do
    if File.dir?(root) do
      root
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.expand/1)
    else
      []
    end
  end

  defp ensure_markdown_file(path) do
    cond do
      path == "" -> {:error, :blank_workflow_path}
      Path.extname(path) |> String.downcase() != ".md" -> {:error, :workflow_path_not_markdown}
      not File.regular?(path) -> {:error, {:missing_workflow_file, path, :enoent}}
      true -> :ok
    end
  end

  defp existing_parent(path) do
    path
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.find(fn candidate -> candidate == Path.dirname(candidate) or File.dir?(candidate) end)
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp ensure_no_active_workers(count, changed_fields) when is_integer(count) and count > 0 and changed_fields != [],
    do: {:error, {:active_workers, count}}

  defp ensure_no_active_workers(:unknown, changed_fields) when changed_fields != [], do: {:error, :active_workers_unknown}

  defp ensure_no_active_workers(_count, _changed_fields), do: :ok

  defp write_backup(path) do
    backup_path = path <> ".bak." <> timestamp()

    case File.cp(path, backup_path) do
      :ok -> {:ok, backup_path}
      {:error, reason} -> {:error, {:backup_failed, reason}}
    end
  end

  defp write_workflow(path, content) do
    temp_path = path <> ".tmp." <> timestamp()

    with :ok <- File.write(temp_path, content),
         :ok <- File.write(path, File.read!(temp_path)) do
      File.rm(temp_path)
      :ok
    else
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp reload_workflow_store do
    if Process.whereis(WorkflowStore) do
      WorkflowStore.force_reload()
    else
      :ok
    end
  end

  defp warnings_for(changed_fields) do
    changed_fields
    |> Enum.flat_map(fn field ->
      case Map.fetch!(@editable_fields, field) do
        %{warning: warning} -> [warning]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp diff(current, proposed) when current == proposed, do: ""

  defp diff(current, proposed) do
    current_lines = String.split(current, "\n")
    proposed_lines = String.split(proposed, "\n")
    max_length = max(length(current_lines), length(proposed_lines))

    indexes(0, max_length)
    |> Enum.flat_map(fn index ->
      old = Enum.at(current_lines, index)
      new = Enum.at(proposed_lines, index)

      cond do
        old == new -> []
        is_nil(old) -> ["+" <> new]
        is_nil(new) -> ["-" <> old]
        true -> ["-" <> old, "+" <> new]
      end
    end)
    |> Enum.join("\n")
  end

  defp content_hash(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_bytes)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(["Z", "."], "")
  end
end
