defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter, WorkerApi}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec worker_status(Conn.t(), map()) :: Conn.t()
  def worker_status(conn, %{"issue_identifier" => issue_identifier}) do
    case WorkerApi.status_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :worker_not_found} ->
        error_response(conn, 404, "worker_not_found", "Worker not found")
    end
  end

  @spec worker_timeline(Conn.t(), map()) :: Conn.t()
  def worker_timeline(conn, %{"issue_identifier" => issue_identifier} = params) do
    case WorkerApi.timeline_payload(issue_identifier, params, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :worker_not_found} ->
        error_response(conn, 404, "worker_not_found", "Worker not found")
    end
  end

  @spec worker_diff(Conn.t(), map()) :: Conn.t()
  def worker_diff(conn, %{"issue_identifier" => issue_identifier} = params) do
    case WorkerApi.diff_payload(issue_identifier, params, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        worker_diff_error(conn, reason)
    end
  end

  @spec worker_debug_events(Conn.t(), map()) :: Conn.t()
  def worker_debug_events(conn, %{"issue_identifier" => issue_identifier} = params) do
    case WorkerApi.debug_events_payload(issue_identifier, params, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :worker_not_found} ->
        error_response(conn, 404, "worker_not_found", "Worker not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec runtime(Conn.t(), map()) :: Conn.t()
  def runtime(conn, _params) do
    json(conn, %{runtime: Presenter.runtime_payload()})
  end

  @spec reload_runtime(Conn.t(), map()) :: Conn.t()
  def reload_runtime(conn, params) do
    with :ok <- authorize_operator(conn, params),
         {:ok, payload} <-
           Presenter.request_reload_payload(orchestrator(), snapshot_timeout_ms(), force: truthy?(Map.get(params, "force"))) do
      conn
      |> put_status(202)
      |> json(%{reload: payload})
    else
      {:error, reason} -> reload_error(conn, reason)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp worker_diff_error(conn, :worker_not_found), do: error_response(conn, 404, "worker_not_found", "Worker not found")
  defp worker_diff_error(conn, :workspace_missing), do: error_response(conn, 404, "workspace_missing", "Worker workspace not found")
  defp worker_diff_error(conn, :not_git_repo), do: error_response(conn, 409, "not_git_repo", "Worker workspace is not a git repository")
  defp worker_diff_error(conn, :workspace_outside_root), do: error_response(conn, 403, "workspace_outside_root", "Worker workspace is outside the configured workspace root")
  defp worker_diff_error(conn, _reason), do: error_response(conn, 500, "diff_unavailable", "Worker diff is unavailable")

  defp reload_error(conn, {:active_workers, count}),
    do: error_response(conn, 409, "active_workers", "Refusing reload while #{count} worker(s) are active")

  defp reload_error(conn, :operator_token_required),
    do: error_response(conn, 403, "operator_token_required", "Operator token is required")

  defp reload_error(conn, :invalid_operator_token),
    do: error_response(conn, 403, "invalid_operator_token", "Operator token is invalid")

  defp reload_error(conn, :dirty_repo),
    do: error_response(conn, 409, "dirty_repo", "Repository has uncommitted changes")

  defp reload_error(conn, :reload_in_progress),
    do: error_response(conn, 409, "reload_in_progress", "A managed reload is already queued or running")

  defp reload_error(conn, :snapshot_timeout),
    do: error_response(conn, 503, "snapshot_timeout", "Snapshot timed out")

  defp reload_error(conn, :snapshot_unavailable),
    do: error_response(conn, 503, "snapshot_unavailable", "Snapshot unavailable")

  defp reload_error(conn, reason),
    do: error_response(conn, 500, "reload_unavailable", "Reload unavailable: #{inspect(reason)}")

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp authorize_operator(conn, params) do
    authorize_operator_token(conn, params, Endpoint.config(:steer_token))
  end

  defp authorize_operator_token(_conn, _params, token) when not is_binary(token),
    do: {:error, :operator_token_required}

  defp authorize_operator_token(conn, params, token) do
    case String.trim(token) do
      "" -> {:error, :operator_token_required}
      expected -> compare_operator_token(operator_token(conn, params), expected)
    end
  end

  defp operator_token(conn, params) do
    Conn.get_req_header(conn, "x-symphony-operator-token")
    |> List.first()
    |> case do
      token when is_binary(token) -> token
      _ -> Map.get(params, "operator_token", "")
    end
  end

  defp compare_operator_token(submitted, expected) do
    submitted = String.trim(submitted || "")

    cond do
      submitted == "" ->
        {:error, :operator_token_required}

      byte_size(submitted) == byte_size(expected) and Plug.Crypto.secure_compare(submitted, expected) ->
        :ok

      true ->
        {:error, :invalid_operator_token}
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy?(_value), do: false
end
