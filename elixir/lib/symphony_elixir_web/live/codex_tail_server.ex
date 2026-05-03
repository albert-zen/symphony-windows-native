defmodule SymphonyElixirWeb.CodexTailServer do
  @moduledoc """
  Per-rollout GenServer that tails a Codex JSONL rollout file and broadcasts
  new conversation items to subscribers over `Phoenix.PubSub`.

  ## Why poll instead of a file watcher?

  Codex writes lines as the session progresses. We could subscribe to OS-level
  filesystem events (`:file_system`), but for the dashboard's needs a small
  polling interval is simpler, watcher-less, cross-platform, and avoids a new
  dependency. The polling interval is short enough (~250ms) that the
  perceived latency is well under the round-trip a human would notice.

  ## Lifecycle

  Started on demand via `start/1`. Stops itself when no subscribers remain
  for `@idle_timeout_ms` after a tick (so abandoned LiveView mounts don't
  keep file handles forever).

  ## Topic

  Subscribers listen on `Phoenix.PubSub` topic
  `"codex_rollout:" <> rollout_id`. Each new line projects through
  `RolloutReader.to_conversation_item/1`; non-nil items are broadcast as
  `{:rollout_item, rollout_id, item}`. We also broadcast
  `{:rollout_state, rollout_id, :truncated}` if the file shrinks
  (Codex compaction or file rotation), so the LiveView can re-load.
  """

  use GenServer
  require Logger

  alias Phoenix.PubSub
  alias SymphonyElixir.Codex.RolloutReader

  @poll_interval_ms 250
  @idle_timeout_ms 30_000

  # ---- API ---------------------------------------------------------------

  @spec topic(String.t()) :: String.t()
  def topic(rollout_id), do: "codex_rollout:" <> rollout_id

  @doc """
  Start (or look up) a tail server for the given rollout id.

  `opts`:
    * `:rollout_id` (required) — usually the JSONL file path or a session id
    * `:path` (required) — absolute path to the rollout file
    * `:pubsub` — defaults to `SymphonyElixir.PubSub`
    * `:supervisor` — defaults to `SymphonyElixirWeb.CodexTailSupervisor`
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    rollout_id = Keyword.fetch!(opts, :rollout_id)
    sup = Keyword.get(opts, :supervisor, SymphonyElixirWeb.CodexTailSupervisor)
    name = via(rollout_id)

    case GenServer.whereis(name) do
      pid when is_pid(pid) ->
        {:ok, pid}

      _ ->
        DynamicSupervisor.start_child(sup, {__MODULE__, opts})
    end
  end

  @doc """
  Subscribe the calling process to a rollout's events. Starts the tailer
  on demand.
  """
  @spec subscribe(keyword()) :: :ok | {:error, term()}
  def subscribe(opts) do
    rollout_id = Keyword.fetch!(opts, :rollout_id)
    pubsub = Keyword.get(opts, :pubsub, SymphonyElixir.PubSub)

    with {:ok, _pid} <- start(opts),
         :ok <- PubSub.subscribe(pubsub, topic(rollout_id)) do
      :ok
    end
  end

  @spec unsubscribe(keyword()) :: :ok
  def unsubscribe(opts) do
    rollout_id = Keyword.fetch!(opts, :rollout_id)
    pubsub = Keyword.get(opts, :pubsub, SymphonyElixir.PubSub)
    PubSub.unsubscribe(pubsub, topic(rollout_id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :rollout_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    rollout_id = Keyword.fetch!(opts, :rollout_id)
    GenServer.start_link(__MODULE__, opts, name: via(rollout_id))
  end

  defp via(rollout_id), do: {:via, Registry, {SymphonyElixirWeb.CodexTailRegistry, rollout_id}}

  # ---- GenServer ---------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      rollout_id: Keyword.fetch!(opts, :rollout_id),
      path: Keyword.fetch!(opts, :path),
      pubsub: Keyword.get(opts, :pubsub, SymphonyElixir.PubSub),
      offset: 0,
      idle_since: System.monotonic_time(:millisecond)
    }

    Process.send_after(self(), :poll, @poll_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll(state)

    cond do
      no_subscribers?(state) and idle_too_long?(state) ->
        {:stop, :normal, state}

      true ->
        Process.send_after(self(), :poll, @poll_interval_ms)

        state =
          if no_subscribers?(state),
            do: state,
            else: %{state | idle_since: System.monotonic_time(:millisecond)}

        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---- internals ---------------------------------------------------------

  defp poll(%{path: path, offset: offset} = state) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size < offset ->
        # File was truncated/rotated. Tell subscribers to reload from scratch.
        broadcast(state, {:rollout_state, state.rollout_id, :truncated})
        %{state | offset: 0}

      {:ok, %File.Stat{size: size}} when size > offset ->
        read_new_lines(state, size)

      _ ->
        state
    end
  end

  defp read_new_lines(%{path: path, offset: offset} = state, size) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, _} = :file.position(io, offset)
          read_loop(io, state, size)
        after
          File.close(io)
        end

      {:error, reason} ->
        Logger.debug("codex_tail: open failed for #{path}: #{inspect(reason)}")
        state
    end
  end

  defp read_loop(io, state, target) do
    case IO.binread(io, :line) do
      :eof ->
        # Re-stat in case the file grew while we were reading.
        case :file.position(io, :cur) do
          {:ok, pos} -> %{state | offset: max(pos, target)}
          _ -> %{state | offset: target}
        end

      {:error, _} ->
        state

      line when is_binary(line) ->
        case decode_and_project(line, state.path) do
          nil -> :ok
          item -> broadcast(state, {:rollout_item, state.rollout_id, item})
        end

        read_loop(io, state, target)
    end
  end

  defp decode_and_project(line, path) do
    case parse_line(line, path) do
      nil -> nil
      parsed -> RolloutReader.to_conversation_item(parsed)
    end
  end

  # Mirrors `RolloutReader.decode_line/2`'s behaviour but is intentionally
  # local so the tail server doesn't depend on private parsing helpers.
  defp parse_line(line, _path) do
    trimmed = String.trim(line)

    if trimmed == "" do
      nil
    else
      case Jason.decode(trimmed) do
        {:ok, %{"type" => "session_meta"} = obj} -> {:meta, obj}
        {:ok, %{"type" => "event_msg"} = obj} -> {:event, obj}
        {:ok, %{"type" => "response_item"} = obj} -> {:response, obj}
        _ -> nil
      end
    end
  end

  defp broadcast(%{pubsub: pubsub, rollout_id: rid}, message) do
    PubSub.broadcast(pubsub, topic(rid), message)
  end

  defp no_subscribers?(%{pubsub: pubsub, rollout_id: rid}) do
    case Registry.lookup(pubsub_registry(pubsub), topic(rid)) do
      [] -> true
      _ -> false
    end
  rescue
    # If the PubSub adapter doesn't expose a Registry, fall back to "always
    # has subscribers" — the idle-timeout still bounds memory because the
    # supervisor restarts the tailer on demand.
    _ -> false
  end

  defp pubsub_registry(pubsub), do: Module.concat(pubsub, "Registry")

  defp idle_too_long?(%{idle_since: since}) do
    System.monotonic_time(:millisecond) - since > @idle_timeout_ms
  end
end
