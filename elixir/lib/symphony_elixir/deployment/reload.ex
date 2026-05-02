defmodule SymphonyElixir.Deployment.Reload do
  @moduledoc """
  Starts a Windows-native managed reload through an external helper process.
  """

  alias SymphonyElixir.{Orchestrator, RuntimeInfo}

  @target_ref "origin/main"
  @request_delay_seconds 3

  @type request_opts :: [
          force: boolean(),
          runtime_info: RuntimeInfo.t(),
          snapshot: map() | :timeout | :unavailable,
          start_fun: (map() -> :ok | {:error, term()}),
          now_fun: (-> DateTime.t()),
          id_fun: (-> String.t())
        ]

  @type request_result :: {:ok, map()} | {:error, atom() | {atom(), term()}}

  @spec request(GenServer.name(), timeout()) :: request_result()
  @spec request(GenServer.name(), timeout(), request_opts()) :: request_result()
  def request(orchestrator, snapshot_timeout_ms, opts \\ []) do
    :global.trans({__MODULE__, :request}, fn ->
      do_request(orchestrator, snapshot_timeout_ms, opts)
    end)
  end

  @spec latest_status(Path.t() | nil) :: map() | nil
  def latest_status(nil), do: nil

  def latest_status(logs_root) when is_binary(logs_root) do
    dir = status_dir(logs_root)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(String.ends_with?(&1, ".json") and not String.ends_with?(&1, ".request.json")))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.sort_by(&File.stat!(&1).mtime, :desc)
        |> List.first()
        |> read_status()

      _ ->
        nil
    end
  rescue
    _error -> nil
  end

  @spec active?(Path.t() | nil) :: boolean()
  def active?(nil), do: false

  def active?(logs_root) when is_binary(logs_root) do
    logs_root
    |> status_files()
    |> Enum.any?(&active_status_file?/1)
  end

  def active?(_logs_root), do: false

  defp do_request(orchestrator, snapshot_timeout_ms, opts) do
    force? = Keyword.get(opts, :force, false)
    runtime_info = Keyword.get_lazy(opts, :runtime_info, &runtime_info/0)
    start_fun = Keyword.get(opts, :start_fun, Application.get_env(:symphony_elixir, :reload_start_fun, &start_helper/1))
    now_fun = Keyword.get(opts, :now_fun, Application.get_env(:symphony_elixir, :reload_now_fun, &DateTime.utc_now/0))
    id_fun = Keyword.get(opts, :id_fun, Application.get_env(:symphony_elixir, :reload_id_fun, &request_id/0))

    with :ok <- validate_runtime_info(runtime_info),
         :ok <- ensure_clean_repo(runtime_info),
         :ok <- ensure_no_active_reload(runtime_info),
         {:ok, payload} <- write_request(runtime_info, force?, now_fun.(), id_fun.()),
         :ok <- ensure_request_can_start(payload, opts, orchestrator, snapshot_timeout_ms, force?),
         :ok <- start_request(payload, start_fun) do
      {:ok, payload}
    else
      {:error, reason, payload} ->
        mark_request_failed(payload, reason)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_no_active_workers(%{running: running}, false) when is_list(running) and running != [] do
    {:error, {:active_workers, length(running)}}
  end

  defp ensure_no_active_workers(%{running: _running}, _force?), do: :ok
  defp ensure_no_active_workers(:timeout, true), do: :ok
  defp ensure_no_active_workers(:unavailable, true), do: :ok
  defp ensure_no_active_workers(:timeout, false), do: {:error, :snapshot_timeout}
  defp ensure_no_active_workers(:unavailable, false), do: {:error, :snapshot_unavailable}
  defp ensure_no_active_workers(_snapshot, _force?), do: {:error, :snapshot_unavailable}

  defp ensure_request_can_start(payload, opts, orchestrator, snapshot_timeout_ms, force?) do
    snapshot = Keyword.get_lazy(opts, :snapshot, fn -> Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) end)

    case ensure_no_active_workers(snapshot, force?) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, payload}
    end
  end

  defp runtime_info do
    Application.get_env(:symphony_elixir, :reload_runtime_info) || RuntimeInfo.snapshot()
  end

  defp validate_runtime_info(%{repo_root: repo_root, workflow_path: workflow_path, logs_root: logs_root, pid_file: pid_file, commit: commit}) do
    cond do
      blank?(repo_root) -> {:error, :repo_root_unavailable}
      blank?(workflow_path) -> {:error, :workflow_path_unavailable}
      blank?(logs_root) -> {:error, :logs_root_unavailable}
      blank?(pid_file) -> {:error, :pid_file_unavailable}
      blank?(commit) -> {:error, :runtime_commit_unavailable}
      not File.exists?(reload_script(repo_root)) -> {:error, {:reload_script_missing, reload_script(repo_root)}}
      true -> :ok
    end
  end

  defp validate_runtime_info(_runtime_info), do: {:error, :runtime_info_unavailable}

  defp ensure_clean_repo(%{dirty?: false}), do: :ok
  defp ensure_clean_repo(%{dirty?: true}), do: {:error, :dirty_repo}
  defp ensure_clean_repo(%{dirty?: nil}), do: {:error, :repo_status_unavailable}

  defp ensure_no_active_reload(%{logs_root: logs_root}) do
    if active?(logs_root), do: {:error, :reload_in_progress}, else: :ok
  end

  defp write_request(runtime_info, force?, requested_at, request_id) do
    dir = status_dir(runtime_info.logs_root)
    :ok = File.mkdir_p(dir)

    status_file = Path.join(dir, "#{request_id}.json")
    request_file = Path.join(dir, "#{request_id}.request.json")
    log_file = Path.join(dir, "#{request_id}.log")

    payload = %{
      request_id: request_id,
      status: "queued",
      requested_at: DateTime.to_iso8601(DateTime.truncate(requested_at, :second)),
      target_ref: @target_ref,
      force: force?,
      repo_root: runtime_info.repo_root,
      workflow_path: runtime_info.workflow_path,
      logs_root: runtime_info.logs_root,
      pid_file: runtime_info.pid_file,
      port: runtime_info.port,
      current_commit: runtime_info.commit,
      status_file: status_file,
      request_file: request_file,
      log_file: log_file,
      script_path: reload_script(runtime_info.repo_root),
      delay_seconds: @request_delay_seconds
    }

    :ok = File.write!(status_file, Jason.encode!(Map.put(payload, :status, "queued"), pretty: true))
    :ok = File.write!(request_file, Jason.encode!(payload, pretty: true))

    {:ok, payload}
  rescue
    error -> {:error, {:request_write_failed, Exception.message(error)}}
  end

  defp mark_request_failed(%{status_file: status_file} = payload, reason) do
    status =
      payload
      |> Map.put(:status, "failed")
      |> Map.put(:message, "Reload request was not started: #{inspect(reason)}")
      |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())

    File.write!(status_file, Jason.encode!(status, pretty: true))
  rescue
    _error -> :ok
  end

  defp start_request(payload, start_fun) do
    case start_fun.(payload) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, payload}
      reason -> {:error, reason, payload}
    end
  end

  defp start_helper(payload) do
    case powershell() do
      {:ok, pwsh} -> start_process(pwsh, payload)
      {:error, reason} -> {:error, reason}
    end
  end

  defp powershell do
    cond do
      path = System.find_executable("pwsh") -> {:ok, path}
      path = System.find_executable("powershell") -> {:ok, path}
      true -> {:error, :powershell_unavailable}
    end
  end

  defp start_process(pwsh, payload) do
    command =
      """
      $args = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', #{ps_quote(payload.script_path)},
        '-RequestFile', #{ps_quote(payload.request_file)}
      )
      Start-Process -FilePath #{ps_quote(pwsh)} -ArgumentList $args -WorkingDirectory #{ps_quote(payload.repo_root)} -WindowStyle Hidden
      """

    case System.cmd(pwsh, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:reload_helper_start_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:reload_helper_start_failed, Exception.message(error)}}
  end

  defp status_dir(logs_root), do: Path.join(logs_root, "reload")

  defp status_files(logs_root) do
    dir = status_dir(logs_root)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(String.ends_with?(&1, ".json") and not String.ends_with?(&1, ".request.json")))
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  defp active_status_file?(path) do
    case read_status(path) do
      %{"status" => status} -> status in ["queued", "running", "rolling_back"]
      %{status: status} -> status in ["queued", "running", "rolling_back"]
      _ -> false
    end
  end

  defp read_status(nil), do: nil

  defp read_status(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  rescue
    _error -> nil
  end

  defp reload_script(repo_root), do: Path.join([repo_root, "elixir", "scripts", "reload-windows-native.ps1"])

  defp request_id do
    "reload-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end

  defp ps_quote(value) do
    "'" <> String.replace(to_string(value), "'", "''") <> "'"
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
