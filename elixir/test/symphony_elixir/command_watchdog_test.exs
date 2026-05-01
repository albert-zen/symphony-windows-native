defmodule SymphonyElixir.CommandWatchdogTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.CommandWatchdog

  @policy %{
    long_running_ms: 1_000,
    idle_ms: 2_000,
    stalled_ms: 5_000,
    repeated_output_limit: 3,
    block_on_stall: false
  }

  test "classifies healthy long-running output" do
    started_at = ~U[2026-05-01 00:00:00Z]

    command =
      nil
      |> CommandWatchdog.update(command_begin(started_at), @policy)
      |> CommandWatchdog.update(output_delta("step 1", DateTime.add(started_at, 2, :second)), @policy)

    snapshot =
      CommandWatchdog.snapshot(command, DateTime.add(started_at, 3, :second), @policy)

    assert snapshot.classification == :healthy
    assert snapshot.last_output_at == DateTime.add(started_at, 2, :second)
    assert snapshot.last_progress_at == DateTime.add(started_at, 2, :second)
  end

  test "classifies no-output command stall" do
    started_at = ~U[2026-05-01 00:00:00Z]
    command = CommandWatchdog.update(nil, command_begin(started_at), @policy)

    snapshot =
      CommandWatchdog.snapshot(command, DateTime.add(started_at, 6, :second), @policy)

    assert snapshot.classification == :stalled
    assert snapshot.idle_ms == 6_000
  end

  test "classifies repeated identical output as needing attention before stall" do
    started_at = ~U[2026-05-01 00:00:00Z]

    command =
      nil
      |> CommandWatchdog.update(command_begin(started_at), @policy)
      |> CommandWatchdog.update(output_delta("make-all pending...", DateTime.add(started_at, 1, :second)), @policy)
      |> CommandWatchdog.update(output_delta("make-all pending...", DateTime.add(started_at, 2, :second)), @policy)
      |> CommandWatchdog.update(output_delta("make-all pending...", DateTime.add(started_at, 3, :second)), @policy)
      |> CommandWatchdog.update(output_delta("make-all pending...", DateTime.add(started_at, 4, :second)), @policy)

    snapshot =
      CommandWatchdog.snapshot(command, DateTime.add(started_at, 4, :second), @policy)

    assert snapshot.classification == :needs_attention
    assert snapshot.repeated_output_count == 3
    assert snapshot.last_progress_at == DateTime.add(started_at, 1, :second)
  end

  test "recovers after new output" do
    started_at = ~U[2026-05-01 00:00:00Z]

    command =
      nil
      |> CommandWatchdog.update(command_begin(started_at), @policy)
      |> CommandWatchdog.update(output_delta("same", DateTime.add(started_at, 1, :second)), @policy)
      |> CommandWatchdog.update(output_delta("same", DateTime.add(started_at, 2, :second)), @policy)
      |> CommandWatchdog.update(output_delta("same", DateTime.add(started_at, 3, :second)), @policy)
      |> CommandWatchdog.update(output_delta("same", DateTime.add(started_at, 4, :second)), @policy)
      |> CommandWatchdog.update(output_delta("new progress", DateTime.add(started_at, 4, :second)), @policy)

    snapshot =
      CommandWatchdog.snapshot(command, DateTime.add(started_at, 4, :second), @policy)

    assert snapshot.classification == :healthy
    assert snapshot.repeated_output_count == 0
    assert snapshot.last_progress_at == DateTime.add(started_at, 4, :second)
  end

  test "tracks app-server item command execution lifecycle" do
    started_at = ~U[2026-05-01 00:00:00Z]

    command =
      nil
      |> CommandWatchdog.update(item_started(["mix", "test"], started_at), @policy)
      |> CommandWatchdog.update(output_delta("running", DateTime.add(started_at, 1, :second)), @policy)

    snapshot =
      CommandWatchdog.snapshot(command, DateTime.add(started_at, 2, :second), @policy)

    assert snapshot.command == "mix test"
    assert snapshot.classification == :healthy
    assert snapshot.last_progress_at == DateTime.add(started_at, 1, :second)

    completed =
      CommandWatchdog.update(command, item_completed(DateTime.add(started_at, 3, :second)), @policy)

    assert CommandWatchdog.snapshot(completed, DateTime.add(started_at, 4, :second), @policy).status ==
             :completed
  end

  test "normalizes mapped parsed commands before storing them" do
    started_at = ~U[2026-05-01 00:00:00Z]

    command =
      CommandWatchdog.update(
        nil,
        command_begin(%{"parsedCmd" => "mix", "args" => ["test", "--stale"]}, started_at),
        @policy
      )

    snapshot =
      CommandWatchdog.snapshot(command, DateTime.add(started_at, 1, :second), @policy)

    assert snapshot.command == "mix test --stale"
  end

  test "ignores non-command item lifecycle events" do
    started_at = ~U[2026-05-01 00:00:00Z]

    assert CommandWatchdog.update(nil, item_started("fileChange", "mix test", started_at), @policy) == nil

    command = CommandWatchdog.update(nil, item_started("commandExecution", "mix test", started_at), @policy)

    completed =
      CommandWatchdog.update(
        command,
        item_completed("fileChange", DateTime.add(started_at, 1, :second)),
        @policy
      )

    assert CommandWatchdog.snapshot(completed, DateTime.add(started_at, 1, :second), @policy).status ==
             :running
  end

  defp command_begin(timestamp) do
    command_begin("make all", timestamp)
  end

  defp command_begin(command, timestamp) do
    %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => command}}
      }
    }
  end

  defp item_started(command, timestamp) do
    item_started("commandExecution", command, timestamp)
  end

  defp item_started(type, command, timestamp) do
    %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "item/started",
        "params" => %{
          "item" => %{
            "type" => type,
            "parsedCmd" => command
          }
        }
      }
    }
  end

  defp item_completed(timestamp) do
    item_completed("commandExecution", timestamp)
  end

  defp item_completed(type, timestamp) do
    %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "item/completed",
        "params" => %{"item" => %{"type" => type}}
      }
    }
  end

  defp output_delta(delta, timestamp) do
    %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "codex/event/exec_command_output_delta",
        "params" => %{"msg" => %{"delta" => delta}}
      }
    }
  end
end
