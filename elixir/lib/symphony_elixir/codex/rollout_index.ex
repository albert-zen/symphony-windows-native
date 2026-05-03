defmodule SymphonyElixir.Codex.RolloutIndex do
  @moduledoc """
  In-memory index of Codex rollout JSONL files on disk, grouped by Symphony
  `issue_identifier`.

  ## Why

  Codex writes a complete append-only transcript per session at
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. The first line of each file
  is a `session_meta` record whose `payload.cwd` is the workspace path. Per
  the Symphony spec the workspace directory name equals the sanitized
  `issue_identifier`, so `Path.basename(cwd)` gives us a free, durable
  mapping back to a Symphony issue — no separate mapping table needed.

  This index lets the Worker Details page resolve historical (and active)
  worker transcripts even after the worker has exited and the orchestrator's
  in-memory state is gone, fixing the previous "404 on terminated worker"
  behaviour of `Presenter.issue_payload/3`.

  ## Configuration

  The sessions root is read from `Application.get_env/3`:

      Application.get_env(:symphony_elixir, :codex_sessions_root, default)

  where `default` is `Path.expand("~/.codex/sessions")`. We also restrict
  to rollouts whose `cwd` falls under the configured workspace root, so we
  do not index unrelated Codex Desktop sessions running on the same
  machine.

  ## Refresh model

  An initial scan runs on `init/1`. After that, `refresh/0` rescans on
  demand. A periodic refresh runs every `@refresh_interval_ms` to catch
  files written by other processes (e.g. Codex during an active run).
  Adopting a filesystem watcher (e.g. `:file_system`) is a future
  improvement and is intentionally not part of this module.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Codex.RolloutReader
  alias SymphonyElixir.Config

  @refresh_interval_ms 30_000

  @typedoc """
  Per-rollout metadata cached in the index.
  """
  @type entry :: %{
          path: Path.t(),
          session_id: String.t() | nil,
          cwd: Path.t() | nil,
          issue_identifier: String.t() | nil,
          started_at: DateTime.t() | nil,
          model: String.t() | nil,
          mtime: integer() | nil
        }

  defmodule State do
    @moduledoc false
    defstruct sessions_root: nil,
              workspace_root: nil,
              # %{issue_identifier => [entry, newest first]}
              by_issue: %{},
              # %{path => entry}
              by_path: %{}
  end

  ## Public API ----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: name(opts))
  end

  @doc """
  Look up all known rollouts for a given Symphony issue identifier.

  Returns a list of entries newest-first (by `started_at`). Returns `[]`
  when the issue is unknown.
  """
  @spec lookup(String.t(), keyword()) :: [entry()]
  def lookup(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    server = name(opts)

    case Process.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(server, {:lookup, issue_identifier})
      _ -> []
    end
  end

  @doc """
  Look up a single rollout by its on-disk path.
  """
  @spec get(Path.t(), keyword()) :: entry() | nil
  def get(path, opts \\ []) when is_binary(path) do
    server = name(opts)
    path = normalize_path(path)

    case Process.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(server, {:get, path})
      _ -> nil
    end
  end

  @doc """
  Force a synchronous rescan of the sessions root.
  """
  @spec refresh(keyword()) :: :ok
  def refresh(opts \\ []) do
    server = name(opts)

    case Process.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(server, :refresh, 30_000)
      _ -> :ok
    end
  end

  @doc """
  Default sessions root: `Path.expand("~/.codex/sessions")` overridable via
  `Application.put_env(:symphony_elixir, :codex_sessions_root, path)`.
  """
  @spec default_sessions_root() :: Path.t()
  def default_sessions_root do
    Application.get_env(:symphony_elixir, :codex_sessions_root, default_sessions_root_path())
  end

  ## GenServer callbacks --------------------------------------------------

  @impl true
  def init(opts) do
    sessions_root =
      opts
      |> Keyword.get(:sessions_root, default_sessions_root())
      |> normalize_path()

    workspace_root = opts |> Keyword.get(:workspace_root, resolve_workspace_root()) |> normalize_path()

    state = %State{sessions_root: sessions_root, workspace_root: workspace_root}
    state = rescan(state)

    schedule_refresh()
    {:ok, state}
  end

  @impl true
  def handle_call({:lookup, issue_identifier}, _from, %State{} = state) do
    {:reply, Map.get(state.by_issue, issue_identifier, []), state}
  end

  def handle_call({:get, path}, _from, %State{} = state) do
    {:reply, Map.get(state.by_path, path), state}
  end

  def handle_call(:refresh, _from, %State{} = state) do
    {:reply, :ok, rescan(state)}
  end

  @impl true
  def handle_info(:refresh, %State{} = state) do
    schedule_refresh()
    {:noreply, rescan(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals ------------------------------------------------------------

  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp rescan(%State{sessions_root: nil} = state), do: state

  defp rescan(%State{sessions_root: root} = state) do
    case File.dir?(root) do
      true ->
        entries =
          root
          |> list_rollout_files()
          |> Enum.map(&entry_for_path(&1, state))
          |> Enum.reject(&is_nil/1)

        index_entries(state, entries)

      false ->
        Logger.debug("rollout_index: sessions root does not exist yet, skipping scan: #{inspect(root)}")

        state
    end
  end

  defp index_entries(%State{} = state, entries) do
    by_path =
      entries
      |> Enum.reduce(%{}, fn entry, acc -> Map.put(acc, entry.path, entry) end)

    by_issue =
      entries
      |> Enum.reject(fn e -> is_nil(e.issue_identifier) end)
      |> Enum.group_by(& &1.issue_identifier)
      |> Enum.into(%{}, fn {issue_id, list} ->
        sorted =
          Enum.sort_by(list, fn e -> e.started_at || DateTime.from_unix!(0) end, {:desc, DateTime})

        {issue_id, sorted}
      end)

    %{state | by_path: by_path, by_issue: by_issue}
  end

  defp list_rollout_files(root) do
    root
    |> Path.join("**/rollout-*.jsonl")
    |> Path.wildcard()
  end

  defp entry_for_path(path, %State{} = state) do
    path = normalize_path(path)
    mtime = file_mtime(path)

    case Map.get(state.by_path, path) do
      %{mtime: ^mtime} = entry when not is_nil(mtime) ->
        entry

      _ ->
        read_entry(path, state, mtime)
    end
  end

  defp read_entry(path, %State{} = state, mtime) do
    case RolloutReader.read_meta(path) do
      {:ok, meta} ->
        cwd = meta.cwd
        issue_identifier = derive_issue_identifier(cwd, state.workspace_root)

        %{
          path: path,
          session_id: meta.session_id,
          cwd: cwd,
          issue_identifier: issue_identifier,
          started_at: meta.started_at,
          model: meta.model,
          mtime: mtime
        }

      {:error, _reason} ->
        nil
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  @doc false
  @spec derive_issue_identifier(Path.t() | nil, Path.t() | nil) :: String.t() | nil
  def derive_issue_identifier(nil, _), do: nil

  def derive_issue_identifier(cwd, workspace_root) when is_binary(cwd) do
    normalized_cwd = normalize_path(cwd)

    if is_binary(workspace_root) and not within_root?(normalized_cwd, workspace_root) do
      nil
    else
      candidate = normalized_cwd |> Path.basename() |> sanitize_identifier()
      if candidate == "", do: nil, else: candidate
    end
  end

  defp within_root?(path, root) do
    p = downcase_for_match(path)
    r = downcase_for_match(root) |> ensure_trailing_separator()
    String.starts_with?(p, r) or p == String.trim_trailing(r, "/")
  end

  defp downcase_for_match(path) do
    path
    |> normalize_path()
    |> String.replace("\\", "/")
    |> String.downcase()
  end

  defp ensure_trailing_separator(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end

  defp sanitize_identifier(value) when is_binary(value) do
    String.replace(value, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp normalize_path(nil), do: nil

  defp normalize_path(path) when is_binary(path) do
    path
    |> Path.expand()
  end

  defp default_sessions_root_path do
    home = System.user_home() || System.get_env("USERPROFILE") || "."
    Path.join([home, ".codex", "sessions"]) |> Path.expand()
  end

  defp resolve_workspace_root do
    Config.settings!().workspace.root
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
