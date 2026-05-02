defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec acquire_issue_claim(Issue.t()) :: {:ok, map()} | {:error, term()}
  def acquire_issue_claim(%Issue{id: issue_id, identifier: identifier}) when is_binary(issue_id) do
    claim = %{
      id: "memory-#{issue_id}",
      owner: "memory",
      claimed_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 4, :hour)
    }

    send_event({:memory_tracker_claim_acquired, issue_id, identifier, claim})
    {:ok, claim}
  end

  def acquire_issue_claim(_issue), do: {:error, :invalid_issue_claim}

  @spec release_issue_claim(String.t()) :: :ok | {:error, term()}
  def release_issue_claim(issue_id), do: release_issue_claim(issue_id, nil)

  @spec release_issue_claim(String.t(), map() | nil) :: :ok | {:error, term()}
  def release_issue_claim(issue_id, _claim) when is_binary(issue_id) do
    send_event({:memory_tracker_claim_released, issue_id})
    :ok
  end

  @spec recover_stale_issue_claim(Issue.t()) :: :ok | {:error, term()}
  def recover_stale_issue_claim(%Issue{id: issue_id, identifier: identifier}) when is_binary(issue_id) do
    send_event({:memory_tracker_claim_recovery_checked, issue_id, identifier})
    :ok
  end

  def recover_stale_issue_claim(_issue), do: {:error, :invalid_issue_claim}

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
