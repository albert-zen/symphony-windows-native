defmodule SymphonyElixir.Codex.CommandWatchdog do
  @moduledoc """
  Tracks active Codex command execution progress and classifies long-running commands.
  """

  @type classification :: :healthy | :idle | :stalled | :needs_attention

  @type policy :: %{
          long_running_ms: non_neg_integer(),
          idle_ms: non_neg_integer(),
          stalled_ms: non_neg_integer(),
          repeated_output_limit: non_neg_integer(),
          block_on_stall: boolean()
        }

  @type t :: map()

  @spec policy_from_config(term()) :: policy()
  def policy_from_config(config) do
    %{
      long_running_ms: Map.get(config, :command_watchdog_long_running_ms, 300_000),
      idle_ms: Map.get(config, :command_watchdog_idle_ms, 120_000),
      stalled_ms: Map.get(config, :command_watchdog_stalled_ms, 300_000),
      repeated_output_limit: Map.get(config, :command_watchdog_repeated_output_limit, 20),
      block_on_stall: Map.get(config, :command_watchdog_block_on_stall, false) == true
    }
  end

  @spec update(t() | nil, map(), policy()) :: t() | nil
  def update(command, %{timestamp: %DateTime{} = timestamp} = update, policy) do
    payload = update[:payload] || Map.get(update, "payload") || update
    method = map_path(payload, ["method"]) || map_path(payload, [:method])

    case command_event(method, payload) do
      :started ->
        new_command(command_name(payload), timestamp)
        |> classify(timestamp, policy)

      :completed ->
        command
        |> mark_completed(timestamp)
        |> classify(timestamp, policy)

      :output ->
        command
        |> apply_output(output_delta(payload), timestamp)
        |> classify(timestamp, policy)

      nil ->
        command && classify(command, timestamp, policy)
    end
  end

  def update(command, _update, _policy), do: command

  @spec classify(t() | nil, DateTime.t(), policy()) :: t() | nil
  def classify(nil, _now, _policy), do: nil

  def classify(%{status: :completed} = command, _now, _policy) do
    %{command | classification: :healthy, classification_reason: "command completed"}
  end

  def classify(%{started_at: %DateTime{} = started_at} = command, %DateTime{} = now, policy) do
    age_ms = elapsed_ms(started_at, now)
    last_progress_at = Map.get(command, :last_progress_at) || started_at
    progress_idle_ms = elapsed_ms(last_progress_at, now)
    repeated_count = Map.get(command, :repeated_output_count, 0)

    {classification, reason} =
      cond do
        age_ms < policy.long_running_ms ->
          {:healthy, "command has not crossed long-running threshold"}

        progress_idle_ms >= policy.stalled_ms ->
          {:stalled, "no command progress for #{progress_idle_ms}ms"}

        repeated_count >= policy.repeated_output_limit ->
          {:needs_attention, "same command output repeated #{repeated_count} times"}

        progress_idle_ms >= policy.idle_ms ->
          {:idle, "no command progress for #{progress_idle_ms}ms"}

        true ->
          {:healthy, "command is producing progress"}
      end

    command
    |> Map.put(:classification, classification)
    |> Map.put(:classification_reason, reason)
  end

  def classify(command, _now, _policy), do: command

  @spec snapshot(t() | nil, DateTime.t(), policy()) :: map() | nil
  def snapshot(nil, _now, _policy), do: nil

  def snapshot(command, now, policy) do
    command = classify(command, now, policy)
    started_at = Map.get(command, :started_at)
    last_output_at = Map.get(command, :last_output_at)
    last_progress_at = Map.get(command, :last_progress_at)

    %{
      command: Map.get(command, :command),
      status: Map.get(command, :status, :running),
      classification: Map.get(command, :classification, :healthy),
      classification_reason: Map.get(command, :classification_reason),
      age_ms: elapsed_ms(started_at, now),
      idle_ms: elapsed_ms(last_progress_at || started_at, now),
      repeated_output_count: Map.get(command, :repeated_output_count, 0),
      started_at: started_at,
      last_output_at: last_output_at,
      last_progress_at: last_progress_at
    }
  end

  defp new_command(command, timestamp) do
    %{
      command: normalize_command(command) || "command",
      status: :running,
      started_at: timestamp,
      last_output_at: nil,
      last_progress_at: timestamp,
      last_output_hash: nil,
      repeated_output_count: 0,
      stalled_policy_action?: false
    }
  end

  defp mark_completed(nil, _timestamp), do: nil

  defp mark_completed(command, timestamp) do
    command
    |> Map.put(:status, :completed)
    |> Map.put(:completed_at, timestamp)
    |> Map.put(:last_progress_at, timestamp)
  end

  defp apply_output(nil, _delta, _timestamp), do: nil
  defp apply_output(command, nil, timestamp), do: %{command | last_output_at: timestamp}

  defp apply_output(command, delta, timestamp) when is_binary(delta) do
    hash = :crypto.hash(:sha256, delta)
    previous_hash = Map.get(command, :last_output_hash)

    if hash == previous_hash do
      command
      |> Map.put(:last_output_at, timestamp)
      |> Map.update(:repeated_output_count, 1, &(&1 + 1))
    else
      command
      |> Map.put(:last_output_at, timestamp)
      |> Map.put(:last_progress_at, timestamp)
      |> Map.put(:last_output_hash, hash)
      |> Map.put(:repeated_output_count, 0)
      |> Map.put(:stalled_policy_action?, false)
    end
  end

  defp command_name(payload) do
    first_path(payload, [
      ["params", "msg", "command"],
      [:params, :msg, :command],
      ["params", "msg", "parsed_cmd"],
      [:params, :msg, :parsed_cmd],
      ["params", "item", "command"],
      [:params, :item, :command],
      ["params", "item", "parsed_cmd"],
      [:params, :item, :parsed_cmd],
      ["params", "item", "parsedCmd"],
      [:params, :item, :parsedCmd],
      ["params", "parsedCmd"],
      [:params, :parsedCmd]
    ])
  end

  defp command_event(method, payload) do
    cond do
      method in ["codex/event/exec_command_begin", "item/commandExecution/begin"] ->
        :started

      command_lifecycle_event?(payload, "item/started") ->
        :started

      method in ["codex/event/exec_command_end", "item/commandExecution/end"] ->
        :completed

      command_lifecycle_event?(payload, "item/completed") ->
        :completed

      method in ["codex/event/exec_command_output_delta", "item/commandExecution/outputDelta"] ->
        :output

      true ->
        nil
    end
  end

  defp command_lifecycle_event?(payload, method) do
    lifecycle_method = map_path(payload, ["method"]) || map_path(payload, [:method])

    item_type =
      map_path(payload, ["params", "item", "type"]) ||
        map_path(payload, [:params, :item, :type])

    lifecycle_method == method and item_type == "commandExecution"
  end

  defp normalize_command(%{} = command) do
    binary_command = first_path(command, [["parsedCmd"], [:parsedCmd], ["parsed_cmd"], [:parsed_cmd], ["command"], [:command], ["cmd"], [:cmd]])
    args = first_path(command, [["args"], [:args], ["argv"], [:argv]])

    if is_binary(binary_command) and is_list(args) do
      normalize_command([binary_command | args])
    else
      normalize_command(binary_command || args)
    end
  end

  defp normalize_command(command) when is_binary(command) do
    command
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> normalize_command()
    end
  end

  defp normalize_command(_command), do: nil

  defp output_delta(payload) do
    map_path(payload, ["params", "msg", "delta"]) ||
      map_path(payload, [:params, :msg, :delta]) ||
      map_path(payload, ["params", "msg", "output"]) ||
      map_path(payload, [:params, :msg, :output]) ||
      map_path(payload, ["params", "outputDelta"]) ||
      map_path(payload, [:params, :outputDelta]) ||
      map_path(payload, ["params", "delta"]) ||
      map_path(payload, [:params, :delta])
  end

  defp first_path(payload, paths) do
    Enum.find_value(paths, &map_path(payload, &1))
  end

  defp elapsed_ms(%DateTime{} = from, %DateTime{} = to), do: max(0, DateTime.diff(to, from, :millisecond))
  defp elapsed_ms(_from, _to), do: nil

  defp map_path(data, [key | rest]) when is_map(data) do
    case fetch_map_key(data, key) do
      {:ok, value} when rest == [] -> value
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  defp map_path(_data, _path), do: nil

  defp fetch_map_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, alternate_key(key))
    end
  end

  defp alternate_key(key) when is_binary(key) do
    String.to_atom(key)
  end

  defp alternate_key(key) when is_atom(key), do: Atom.to_string(key)
end
