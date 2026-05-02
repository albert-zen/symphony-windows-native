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

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
