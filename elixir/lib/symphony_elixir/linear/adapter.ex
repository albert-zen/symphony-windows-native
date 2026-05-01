defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @claim_ttl_seconds 4 * 60 * 60
  @claim_settle_ms 250
  @claim_marker "## Symphony Claim Lease"
  @claim_release_marker "## Symphony Claim Release"

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
        createdAt
      }
    }
  }
  """

  @claim_comments_query """
  query SymphonyIssueClaimComments($issueId: String!, $after: String) {
    issue(id: $issueId) {
      comments(first: 100, after: $after) {
        nodes {
          id
          body
          createdAt
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec acquire_issue_claim(term()) :: {:ok, map()} | {:error, term()}
  def acquire_issue_claim(%{id: issue_id, identifier: identifier}) when is_binary(issue_id) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, @claim_ttl_seconds, :second)
    owner = claim_owner()
    token = claim_token()
    body = claim_body(identifier, owner, token, now, expires_at)

    with {:ok, claim} <- create_claim_comment(issue_id, body, owner, token, now, expires_at) do
      verify_issue_claim(issue_id, claim)
    end
  end

  def acquire_issue_claim(_issue), do: {:error, :invalid_issue_claim}

  @spec release_issue_claim(String.t()) :: :ok | {:error, term()}
  def release_issue_claim(issue_id), do: release_issue_claim(issue_id, nil)

  @spec release_issue_claim(String.t(), map() | nil) :: :ok | {:error, term()}
  def release_issue_claim(issue_id, nil) when is_binary(issue_id), do: :ok

  def release_issue_claim(issue_id, claim) when is_binary(issue_id) do
    owner = claim_value(claim, :owner)
    token = claim_value(claim, :token)

    if is_binary(owner) and is_binary(token) do
      body = release_body(owner, token, DateTime.utc_now())

      with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
           true <- get_in(response, ["data", "commentCreate", "success"]) == true do
        :ok
      else
        false -> {:error, :claim_release_failed}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :claim_release_failed}
      end
    else
      :ok
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp create_claim_comment(issue_id, body, owner, token, now, expires_at) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      comment = get_in(response, ["data", "commentCreate", "comment"]) || %{}

      {:ok,
       %{
         id: comment["id"],
         owner: owner,
         token: token,
         claimed_at: parse_datetime(comment["createdAt"]) || now,
         expires_at: expires_at
       }}
    else
      false -> {:error, :claim_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :claim_create_failed}
    end
  end

  defp wait_for_concurrent_claims do
    Process.sleep(@claim_settle_ms)
    :ok
  end

  defp verify_issue_claim(issue_id, claim) do
    result =
      with :ok <- wait_for_concurrent_claims(),
           {:ok, claims} <- fetch_claim_comments(issue_id),
           {:ok, winner} <- winning_claim(claims, DateTime.utc_now()) do
        if same_claim?(winner, claim) do
          {:ok, winner}
        else
          {:error, {:issue_claimed, winner}}
        end
      end

    case result do
      {:ok, winner} ->
        {:ok, winner}

      {:error, reason} ->
        _ = release_issue_claim(issue_id, claim)
        {:error, reason}
    end
  end

  defp fetch_claim_comments(issue_id) do
    fetch_claim_comments_page(issue_id, nil, [])
  end

  defp fetch_claim_comments_page(issue_id, after_cursor, acc) do
    with {:ok, response} <- client_module().graphql(@claim_comments_query, %{issueId: issue_id, after: after_cursor}),
         comments when is_list(comments) <- get_in(response, ["data", "issue", "comments", "nodes"]) do
      parsed = parse_claim_comments(comments)
      page_info = get_in(response, ["data", "issue", "comments", "pageInfo"]) || %{}

      if page_info["hasNextPage"] == true and is_binary(page_info["endCursor"]) do
        fetch_claim_comments_page(issue_id, page_info["endCursor"], parsed ++ acc)
      else
        {:ok, parsed ++ acc}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :claim_comments_fetch_failed}
    end
  end

  defp winning_claim(claims, now) when is_list(claims) do
    releases =
      claims
      |> Enum.filter(&(&1.type == :release))
      |> Enum.group_by(& &1.owner)

    claims
    |> Enum.filter(&(&1.type == :claim))
    |> Enum.reject(&(claim_expired?(&1, now) or claim_released?(&1, releases)))
    |> Enum.sort_by(fn claim ->
      {DateTime.to_unix(claim.claimed_at, :microsecond), claim.id || "", claim.token || ""}
    end)
    |> case do
      [claim | _] -> {:ok, claim}
      [] -> {:error, :claim_not_visible}
    end
  end

  defp parse_claim_comments(comments) do
    comments
    |> Enum.flat_map(&parse_claim_comment/1)
  end

  defp parse_claim_comment(%{"id" => id, "body" => body, "createdAt" => created_at})
       when is_binary(body) do
    fields = claim_fields(body)
    comment_created_at = parse_datetime(created_at)

    cond do
      String.starts_with?(body, @claim_marker) ->
        claim = %{
          type: :claim,
          id: id,
          owner: Map.get(fields, "owner"),
          token: Map.get(fields, "token"),
          claimed_at: parse_datetime(Map.get(fields, "claimed_at")) || comment_created_at,
          expires_at: parse_datetime(Map.get(fields, "expires_at"))
        }

        if valid_claim?(claim), do: [claim], else: []

      String.starts_with?(body, @claim_release_marker) ->
        release = %{
          type: :release,
          id: id,
          owner: Map.get(fields, "owner"),
          token: Map.get(fields, "token"),
          released_at: parse_datetime(Map.get(fields, "released_at")) || comment_created_at
        }

        if valid_release?(release), do: [release], else: []

      true ->
        []
    end
  end

  defp parse_claim_comment(_comment), do: []

  defp claim_fields(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, fields ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          Map.put(fields, String.trim(key), String.trim(value))

        _ ->
          fields
      end
    end)
  end

  defp valid_claim?(%{owner: owner, claimed_at: %DateTime{}, expires_at: %DateTime{}})
       when is_binary(owner),
       do: String.trim(owner) != ""

  defp valid_claim?(_claim), do: false

  defp valid_release?(%{owner: owner, token: token, released_at: %DateTime{}})
       when is_binary(owner) and is_binary(token),
       do: String.trim(owner) != "" and String.trim(token) != ""

  defp valid_release?(_release), do: false

  defp claim_expired?(%{expires_at: expires_at}, now), do: DateTime.compare(expires_at, now) != :gt

  defp claim_released?(%{owner: owner, token: token, claimed_at: claimed_at}, releases) do
    releases
    |> Map.get(owner, [])
    |> Enum.any?(fn release ->
      release_token = Map.get(release, :token)

      release_token == token and DateTime.compare(release.released_at, claimed_at) in [:gt, :eq]
    end)
  end

  defp same_claim?(claim, expected_claim) do
    claim_value(claim, :owner) == claim_value(expected_claim, :owner) and
      claim_value(claim, :token) == claim_value(expected_claim, :token)
  end

  defp claim_value(claim, key) when is_map(claim), do: Map.get(claim, key) || Map.get(claim, Atom.to_string(key))
  defp claim_value(_claim, _key), do: nil

  defp claim_body(identifier, owner, token, claimed_at, expires_at) do
    [
      @claim_marker,
      "",
      "owner: #{owner}",
      "token: #{token}",
      "issue: #{identifier || "unknown"}",
      "claimed_at: #{DateTime.to_iso8601(claimed_at)}",
      "expires_at: #{DateTime.to_iso8601(expires_at)}",
      "",
      "Symphony dispatch lease. A newer worker must not dispatch this issue while this lease is unexpired unless this owner has released it."
    ]
    |> Enum.join("\n")
  end

  defp release_body(owner, token, released_at) do
    [
      @claim_release_marker,
      "",
      "owner: #{owner}",
      "token: #{token}",
      "released_at: #{DateTime.to_iso8601(released_at)}"
    ]
    |> Enum.join("\n")
  end

  defp claim_owner do
    case Process.get({__MODULE__, :claim_owner}) do
      owner when is_binary(owner) ->
        owner

      _ ->
        owner =
          [
            hostname(),
            System.pid(),
            inspect(self()),
            :erlang.unique_integer([:positive, :monotonic])
          ]
          |> Enum.join(":")

        Process.put({__MODULE__, :claim_owner}, owner)
        owner
    end
  end

  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end

  defp claim_token do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
