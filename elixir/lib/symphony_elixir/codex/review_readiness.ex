defmodule SymphonyElixir.Codex.ReviewReadiness do
  @moduledoc """
  Guards agent-initiated Linear `In Review` transitions.
  """

  @github_api "https://api.github.com"
  @github_accept "application/vnd.github+json"
  @passing_status_states MapSet.new(["success"])
  @passing_check_conclusions MapSet.new(["success", "neutral", "skipped"])
  alias SymphonyElixir.Config

  @context_query """
  query SymphonyReviewReadinessContext($issueId: String!) {
    issue(id: $issueId) {
      id
      identifier
      url
      team {
        states(first: 250) {
          nodes {
            id
            name
          }
        }
      }
      attachments {
        nodes {
          title
          url
        }
      }
      comments(first: 50) {
        nodes {
          id
          body
        }
      }
    }
  }
  """

  @create_comment_mutation """
  mutation SymphonyReviewReadinessCreateWorkpad($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyReviewReadinessUpdateWorkpad($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
    }
  }
  """

  @spec authorize_linear_graphql(String.t(), map(), function(), function()) ::
          :ok | {:error, {:review_readiness_rejected, map()}}
  def authorize_linear_graphql(query, variables, linear_client, github_client)
      when is_binary(query) and is_map(variables) and is_function(linear_client) and is_function(github_client) do
    case transition_request(query, variables) do
      {:ok, issue_id, state_id} ->
        authorize_transition(issue_id, state_id, variables, linear_client, github_client)

      :not_state_transition ->
        :ok

      {:error, reason} ->
        reject(nil, reason, linear_client)
    end
  end

  @spec github_get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def github_get(url, opts \\ []) when is_binary(url) and is_list(opts) do
    headers =
      [
        {"Accept", @github_accept},
        {"User-Agent", "symphony-review-readiness"}
      ]
      |> maybe_add_github_token()

    Req.get(url, headers: headers, connect_options: [timeout: Keyword.get(opts, :timeout, 30_000)])
  end

  defp authorize_transition(issue_id, state_id, variables, linear_client, github_client) do
    with {:ok, issue} <- fetch_issue_context(issue_id, linear_client),
         {:ok, destination_state} <- destination_state(issue, state_id) do
      authorize_destination(issue, destination_state, variables, linear_client, github_client)
    else
      {:error, reason} -> reject(issue_id, reason, linear_client)
    end
  end

  defp authorize_destination(issue, destination_state, variables, linear_client, github_client) do
    cond do
      not in_review_state?(destination_state) ->
        :ok

      manager_override?(variables) ->
        reject(issue, :review_readiness_agent_override_not_allowed, linear_client)

      true ->
        verify_review_ready(issue, linear_client, github_client)
    end
  end

  defp verify_review_ready(issue, linear_client, github_client) do
    with {:ok, pr} <- linked_pull_request(issue),
         :ok <- required_checks_passed?(issue, pr, github_client) do
      :ok
    else
      {:error, reason} -> reject(issue, reason, linear_client)
    end
  end

  defp transition_request(query, variables) do
    executable_query = executable_graphql(query)
    issue_update_count = issue_update_count(executable_query)

    cond do
      issue_update_count == 0 ->
        :not_state_transition

      issue_update_count > 1 ->
        {:error, :review_readiness_multiple_issue_updates}

      true ->
        transition_request_from_issue_update(query, executable_query, variables)
    end
  end

  defp transition_request_from_issue_update(query, executable_query, variables) do
    with {:ok, arguments, executable_arguments} <- issue_update_arguments(query, executable_query) do
      if explicit_state_id?(executable_arguments) do
        explicit_transition_request(arguments, executable_arguments, variables)
      else
        input_transition_request(arguments, executable_arguments, variables)
      end
    end
  end

  defp explicit_transition_request(arguments, executable_arguments, variables) do
    with {:ok, issue_id} <- issue_id_from(arguments, executable_arguments, variables),
         {:ok, state_id} <- explicit_state_id_from(arguments, executable_arguments, variables) do
      {:ok, issue_id, state_id}
    end
  end

  defp issue_update_arguments(query, executable_query) do
    case Regex.run(~r/\bissueUpdate\s*\((.*?)\)\s*\{/s, executable_query, return: :index) do
      [{_match_start, _match_length}, {arguments_start, arguments_length}] ->
        original_arguments = binary_part(query, arguments_start, arguments_length)
        executable_arguments = binary_part(executable_query, arguments_start, arguments_length)

        {:ok, original_arguments, executable_arguments}

      _ ->
        {:error, :review_readiness_issue_update_unverifiable}
    end
  end

  defp input_transition_request(arguments, executable_arguments, variables) do
    case input_state_id_from(executable_arguments, variables) do
      {:ok, state_id} -> issue_transition_request(arguments, executable_arguments, variables, state_id)
      nil -> :not_state_transition
    end
  end

  defp issue_transition_request(arguments, executable_arguments, variables, state_id) do
    with {:ok, issue_id} <- issue_id_from(arguments, executable_arguments, variables) do
      {:ok, issue_id, state_id}
    end
  end

  defp issue_update_count(query) do
    ~r/\bissueUpdate\s*\(/
    |> Regex.scan(query)
    |> length()
  end

  defp executable_graphql(query) do
    query
    |> executable_graphql([])
    |> IO.iodata_to_binary()
  end

  defp executable_graphql(<<>>, acc), do: Enum.reverse(acc)

  defp executable_graphql(<<"\"\"\"", rest::binary>>, acc) do
    {rest, acc} = blank_block_string(rest, ["\"\"\"" | acc])
    executable_graphql(rest, acc)
  end

  defp executable_graphql(<<"\"", rest::binary>>, acc) do
    {rest, acc} = blank_string(rest, ["\"" | acc])
    executable_graphql(rest, acc)
  end

  defp executable_graphql(<<"#", rest::binary>>, acc) do
    {rest, acc} = blank_graphql_comment(rest, [" " | acc])
    executable_graphql(rest, acc)
  end

  defp executable_graphql(<<0xEF, 0xBB, 0xBF, rest::binary>>, acc) do
    executable_graphql(rest, ["   " | acc])
  end

  defp executable_graphql(<<char, rest::binary>>, acc) when char in [?\t, ?\n, ?\r, ?,] do
    executable_graphql(rest, [" " | acc])
  end

  defp executable_graphql(<<char, rest::binary>>, acc) do
    executable_graphql(rest, [<<char>> | acc])
  end

  defp blank_graphql_comment(<<>>, acc), do: {<<>>, acc}
  defp blank_graphql_comment(<<"\r\n", rest::binary>>, acc), do: {rest, ["  " | acc]}
  defp blank_graphql_comment(<<"\n", rest::binary>>, acc), do: {rest, [" " | acc]}
  defp blank_graphql_comment(<<"\r", rest::binary>>, acc), do: {rest, [" " | acc]}
  defp blank_graphql_comment(<<_char, rest::binary>>, acc), do: blank_graphql_comment(rest, [" " | acc])

  defp blank_string(<<>>, acc), do: {<<>>, acc}
  defp blank_string(<<"\\", _escaped, rest::binary>>, acc), do: blank_string(rest, ["  " | acc])
  defp blank_string(<<"\"", rest::binary>>, acc), do: {rest, ["\"" | acc]}
  defp blank_string(<<_char, rest::binary>>, acc), do: blank_string(rest, [" " | acc])

  defp blank_block_string(<<>>, acc), do: {<<>>, acc}
  defp blank_block_string(<<"\"\"\"", rest::binary>>, acc), do: {rest, ["\"\"\"" | acc]}
  defp blank_block_string(<<_char, rest::binary>>, acc), do: blank_block_string(rest, [" " | acc])

  defp explicit_state_id?(query) do
    String.contains?(query, "stateId")
  end

  defp issue_id_from(arguments, executable_arguments, variables) do
    variable_value(executable_arguments, variables, ~r/\bid\s*:\s*\$(\w+)/) ||
      literal_field_value(arguments, executable_arguments, "id") ||
      {:error, :review_readiness_missing_issue_id}
  end

  defp explicit_state_id_from(arguments, executable_arguments, variables) do
    variable_value(executable_arguments, variables, ~r/stateId\s*:\s*\$(\w+)/) ||
      literal_field_value(arguments, executable_arguments, "stateId") ||
      {:error, :review_readiness_missing_state_id}
  end

  defp input_state_id_from(query, variables) do
    case Regex.run(~r/\binput\s*:\s*\$(\w+)/, query) do
      [_, variable_name] ->
        with input when is_map(input) <- variable_map_value(variables, variable_name),
             state_id when is_binary(state_id) and state_id != "" <- Map.get(input, "stateId") || Map.get(input, :stateId) do
          {:ok, state_id}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp variable_value(query, variables, regex) do
    case Regex.run(regex, query) do
      [_, variable_name] ->
        case variable_map_value(variables, variable_name) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> {:error, {:review_readiness_missing_variable, variable_name}}
        end

      _ ->
        nil
    end
  end

  defp variable_map_value(variables, variable_name) do
    Map.get(variables, variable_name) || Map.get(variables, String.to_existing_atom(variable_name))
  rescue
    ArgumentError -> Map.get(variables, variable_name)
  end

  defp literal_field_value(arguments, executable_arguments, field_name) do
    regex = Regex.compile!("\\b#{field_name}\\s*:\\s*\"[^\"]*\"")

    case Regex.run(regex, executable_arguments, return: :index) do
      [{start, length}] ->
        literal_segment = binary_part(arguments, start, length)

        case Regex.run(~r/"([^"]+)"/, literal_segment) do
          [_, value] -> {:ok, value}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_issue_context(issue_id, linear_client) do
    case linear_client.(@context_query, %{"issueId" => issue_id}, []) do
      {:ok, %{"data" => %{"issue" => issue}}} when is_map(issue) -> {:ok, issue}
      {:ok, _payload} -> {:error, :review_readiness_issue_unverifiable}
      {:error, reason} -> {:error, {:review_readiness_issue_unverifiable, reason}}
    end
  end

  defp destination_state(issue, state_id) do
    issue
    |> get_in(["team", "states", "nodes"])
    |> case do
      states when is_list(states) ->
        case Enum.find(states, &(Map.get(&1, "id") == state_id)) do
          %{"name" => name} when is_binary(name) -> {:ok, name}
          _ -> {:error, :review_readiness_destination_state_unverifiable}
        end

      _ ->
        {:error, :review_readiness_destination_state_unverifiable}
    end
  end

  defp in_review_state?(state_name) when is_binary(state_name) do
    normalize(state_name) == "in review"
  end

  defp manager_override?(variables) do
    truthy?(Map.get(variables, "symphonyManagerOverride") || Map.get(variables, :symphonyManagerOverride)) and
      override_reason(variables) != nil
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("yes"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  defp override_reason(variables) do
    case Map.get(variables, "symphonyManagerOverrideReason") || Map.get(variables, :symphonyManagerOverrideReason) do
      reason when is_binary(reason) ->
        case String.trim(reason) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp linked_pull_request(issue) do
    issue
    |> pull_request_urls()
    |> Enum.find_value(&parse_pull_request_url/1)
    |> case do
      nil -> {:error, :review_readiness_missing_linked_pull_request}
      pr -> {:ok, pr}
    end
  end

  defp pull_request_urls(issue) do
    attachment_urls =
      issue
      |> get_in(["attachments", "nodes"])
      |> case do
        attachments when is_list(attachments) -> Enum.map(attachments, &Map.get(&1, "url"))
        _ -> []
      end

    attachment_urls
  end

  defp parse_pull_request_url(url) when is_binary(url) do
    case Regex.run(~r/^https:\/\/github\.com\/([^\/]+)\/([^\/]+)\/pull\/(\d+)/, url) do
      [_, owner, repo, number] -> %{owner: owner, repo: repo, number: number}
      _ -> nil
    end
  end

  defp parse_pull_request_url(_url), do: nil

  defp required_checks_passed?(issue, %{owner: owner, repo: repo, number: number}, github_client) do
    with {:ok, pr} <- github_json(github_client, "#{@github_api}/repos/#{owner}/#{repo}/pulls/#{number}"),
         :ok <- pull_request_matches_issue?(issue, owner, repo, pr),
         {:ok, head_sha} <- required_string(pr, ["head", "sha"], :review_readiness_missing_pr_head_sha),
         {:ok, base_ref} <- required_string(pr, ["base", "ref"], :review_readiness_missing_pr_base_ref),
         :ok <- pull_request_file_count_fetchable?(pr),
         {:ok, pr_files} <- pull_request_files(owner, repo, number, github_client),
         :ok <- coverage_ignore_ready?(owner, repo, head_sha, pr_files, github_client),
         {:ok, merge_base_sha} <- merge_base_sha(owner, repo, base_ref, head_sha, github_client),
         :ok <- stale_base_ready?(owner, repo, base_ref, merge_base_sha, pr_files, github_client),
         {:ok, required_checks} <-
           required_checks(owner, repo, base_ref, github_client),
         {:ok, statuses} <- github_json(github_client, "#{@github_api}/repos/#{owner}/#{repo}/commits/#{head_sha}/status"),
         {:ok, check_runs} <- github_json(github_client, "#{@github_api}/repos/#{owner}/#{repo}/commits/#{head_sha}/check-runs") do
      verify_contexts(required_checks, statuses, check_runs)
    end
  end

  defp pull_request_matches_issue?(issue, owner, repo, pr) do
    with :ok <- expected_repository?(owner, repo),
         :ok <- head_repository_matches?(pr),
         do: pull_request_branch_matches_issue?(issue, pr)
  end

  defp expected_repository?(owner, repo) do
    expected =
      Config.settings!().codex.review_readiness_repository
      |> normalize_repo_name()

    actual = normalize_repo_name("#{owner}/#{repo}")

    cond do
      is_nil(expected) -> {:error, :review_readiness_repository_unconfigured}
      expected == actual -> :ok
      true -> {:error, {:review_readiness_untrusted_repository, "#{owner}/#{repo}"}}
    end
  rescue
    _ -> {:error, :review_readiness_repository_unconfigured}
  end

  defp head_repository_matches?(pr) do
    expected =
      Config.settings!().codex.review_readiness_repository
      |> normalize_repo_name()

    head_repository =
      pr
      |> get_in(["head", "repo", "full_name"])
      |> normalize_repo_name()

    cond do
      is_nil(expected) -> {:error, :review_readiness_repository_unconfigured}
      is_nil(head_repository) -> {:error, :review_readiness_pr_head_repository_unverifiable}
      expected == head_repository -> :ok
      true -> {:error, {:review_readiness_untrusted_head_repository, head_repository}}
    end
  rescue
    _ -> {:error, :review_readiness_repository_unconfigured}
  end

  defp pull_request_branch_matches_issue?(issue, pr) do
    identifier = issue_identifier(issue)
    head_ref = get_in(pr, ["head", "ref"])

    cond do
      is_nil(identifier) ->
        {:error, :review_readiness_issue_identifier_missing}

      not is_binary(head_ref) or String.trim(head_ref) == "" ->
        {:error, :review_readiness_pr_branch_unverifiable}

      branch_matches_issue_identifier?(head_ref, identifier) ->
        :ok

      true ->
        {:error, {:review_readiness_pr_branch_mismatch, head_ref, identifier}}
    end
  end

  defp branch_matches_issue_identifier?(head_ref, identifier) do
    pattern = ~r/(^|-)#{Regex.escape(normalized_branch_token(identifier))}($|-)/

    Regex.match?(pattern, normalized_branch_token(head_ref))
  end

  defp issue_identifier(issue) do
    case Map.get(issue, "identifier") do
      identifier when is_binary(identifier) and identifier != "" -> identifier
      _ -> nil
    end
  end

  defp normalize_repo_name(nil), do: nil

  defp normalize_repo_name(repo) when is_binary(repo) do
    repo
    |> String.trim()
    |> String.trim_leading("https://github.com/")
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp normalized_branch_token(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp required_checks(owner, repo, base_ref, github_client) do
    encoded_base_ref = URI.encode(base_ref, &URI.char_unreserved?/1)
    protection_url = "#{@github_api}/repos/#{owner}/#{repo}/branches/#{encoded_base_ref}/protection/required_status_checks"

    case github_json(github_client, protection_url) do
      {:ok, protection} -> required_check_specs(protection)
      {:error, reason} -> configured_required_checks_or_error(reason)
    end
  end

  defp github_json(github_client, url) do
    case github_client.(url, []) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:review_readiness_github_unverifiable, status, summarize_body(body)}}

      {:error, reason} ->
        {:error, {:review_readiness_github_unverifiable, reason}}
    end
  end

  defp github_json_list(github_client, url) do
    case github_client.(url, []) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_list(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:review_readiness_github_unverifiable, status, summarize_body(body)}}

      {:error, reason} ->
        {:error, {:review_readiness_github_unverifiable, reason}}
    end
  end

  defp pull_request_files(owner, repo, number, github_client) do
    github_json_list(github_client, "#{@github_api}/repos/#{owner}/#{repo}/pulls/#{number}/files?per_page=100")
  end

  defp pull_request_file_count_fetchable?(%{"changed_files" => changed_files})
       when is_integer(changed_files) and changed_files > 100 do
    {:error, {:review_readiness_pr_file_list_too_large, changed_files}}
  end

  defp pull_request_file_count_fetchable?(_pr), do: :ok

  defp coverage_ignore_ready?(owner, repo, head_sha, files, github_client) do
    changed_modules = changed_production_modules(files)

    with {:ok, ignored_modules} <- added_coverage_ignore_modules(owner, repo, head_sha, files, github_client) do
      changed_module_keys = normalized_module_set(changed_modules)

      overlap =
        ignored_modules
        |> Enum.filter(&changed_module_ignored?(&1, changed_module_keys))
        |> Enum.sort()

      if overlap == [] do
        :ok
      else
        {:error, {:review_readiness_coverage_ignore_changed_modules, overlap}}
      end
    end
  end

  defp normalized_module_set(modules) do
    modules
    |> Enum.map(&normalize_module_name/1)
    |> MapSet.new()
  end

  defp normalize_module_name(module) do
    module
    |> String.trim()
    |> String.downcase()
  end

  defp changed_module_ignored?(ignored_module, changed_module_keys) do
    ignored_key = normalize_module_name(ignored_module)

    Enum.any?(changed_module_keys, fn changed_key ->
      ignored_key == changed_key or String.starts_with?(ignored_key, changed_key <> ".")
    end)
  end

  defp changed_production_modules(files) do
    Enum.reduce(files, MapSet.new(), fn file, acc ->
      filename = Map.get(file, "filename")
      status = Map.get(file, "status")
      patch = Map.get(file, "patch")

      if production_elixir_file?(filename) and status != "removed" do
        path_module = module_name_from_path(filename)

        patch
        |> module_names_from_patch(path_module)
        |> Enum.reduce(MapSet.put(acc, path_module), &MapSet.put(&2, &1))
      else
        acc
      end
    end)
  end

  defp production_elixir_file?(filename) when is_binary(filename) do
    (String.starts_with?(filename, "lib/") or String.starts_with?(filename, "elixir/lib/")) and
      String.ends_with?(filename, ".ex")
  end

  defp production_elixir_file?(_filename), do: false

  defp module_name_from_path(filename) do
    filename
    |> String.trim_leading("elixir/")
    |> String.trim_leading("lib/")
    |> String.trim_trailing(".ex")
    |> String.split("/", trim: true)
    |> Enum.map_join(".", &Macro.camelize/1)
  end

  defp module_names_from_patch(patch, path_module) when is_binary(patch) do
    Regex.scan(~r/^[ +]\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)\s+do/m, patch)
    |> Enum.flat_map(fn [_, module] -> changed_module_names(module, path_module) end)
  end

  defp module_names_from_patch(_patch, _path_module), do: []

  defp changed_module_names(module, path_module) do
    if String.contains?(module, ".") do
      [module]
    else
      [module, path_module <> "." <> module]
    end
  end

  defp added_coverage_ignore_modules(owner, repo, head_sha, files, github_client) do
    files
    |> Enum.filter(&(Map.get(&1, "filename") == "mix.exs" or String.ends_with?(Map.get(&1, "filename") || "", "/mix.exs")))
    |> Enum.reduce_while({:ok, MapSet.new()}, fn file, {:ok, acc} ->
      added_coverage_ignore_modules_for_file(owner, repo, head_sha, file, github_client, acc)
    end)
  end

  defp added_coverage_ignore_modules_for_file(owner, repo, head_sha, file, github_client, acc) do
    candidates =
      file
      |> Map.get("patch", "")
      |> added_elixir_module_candidates()

    case candidates do
      [] ->
        {:cont, {:ok, acc}}

      candidates ->
        add_coverage_ignore_candidates(owner, repo, head_sha, file, github_client, acc, candidates)
    end
  end

  defp add_coverage_ignore_candidates(owner, repo, head_sha, file, github_client, acc, candidates) do
    case github_file_lines(owner, repo, Map.fetch!(file, "filename"), head_sha, github_client) do
      {:ok, lines} -> {:cont, {:ok, MapSet.union(acc, coverage_ignore_modules_at_lines(candidates, lines))}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp coverage_ignore_modules_at_lines(candidates, lines) do
    ranges = coverage_ignore_line_ranges(lines)

    candidates
    |> Enum.filter(fn {_module, line_number} -> line_in_ranges?(line_number, ranges) end)
    |> Enum.map(fn {module, _line_number} -> module end)
    |> MapSet.new()
  end

  defp added_elixir_module_candidates(patch) when is_binary(patch) do
    patch
    |> String.split("\n")
    |> Enum.reduce(%{line_number: nil, modules: []}, &added_elixir_module_candidate/2)
    |> Map.fetch!(:modules)
    |> Enum.reverse()
  end

  defp added_elixir_module_candidates(_patch), do: []

  defp added_elixir_module_candidate(line, state) do
    cond do
      hunk_start = hunk_new_start(line) ->
        %{state | line_number: hunk_start - 1}

      state.line_number == nil ->
        state

      deleted_line?(line) ->
        state

      added_line?(line) ->
        state
        |> increment_line_number()
        |> maybe_add_candidate(line)

      true ->
        increment_line_number(state)
    end
  end

  defp hunk_new_start(line) do
    case Regex.run(~r/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/, line) do
      [_, start] -> String.to_integer(start)
      _ -> nil
    end
  end

  defp increment_line_number(%{line_number: line_number} = state) when is_integer(line_number),
    do: %{state | line_number: line_number + 1}

  defp increment_line_number(state), do: state

  defp maybe_add_candidate(%{line_number: line_number, modules: modules} = state, line) do
    case added_module_from_line(line) do
      nil -> state
      module -> %{state | modules: [{module, line_number} | modules]}
    end
  end

  defp github_file_lines(owner, repo, filename, ref, github_client) do
    path = filename |> String.split("/") |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
    encoded_ref = URI.encode(ref, &URI.char_unreserved?/1)

    with {:ok, content} <- github_json(github_client, "#{@github_api}/repos/#{owner}/#{repo}/contents/#{path}?ref=#{encoded_ref}"),
         {:ok, decoded} <- decode_github_content(content) do
      {:ok, String.split(decoded, ~r/\R/)}
    end
  end

  defp decode_github_content(%{"encoding" => "base64", "content" => content}) when is_binary(content) do
    content
    |> String.replace(~r/\s+/, "")
    |> Base.decode64()
    |> case do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :review_readiness_github_content_unreadable}
    end
  end

  defp decode_github_content(_content), do: {:error, :review_readiness_github_content_unreadable}

  defp coverage_ignore_line_ranges(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce(%{test_coverage_depth: 0, ignore_start: nil, ranges: []}, &coverage_ignore_line_range/2)
    |> Map.fetch!(:ranges)
    |> Enum.reverse()
  end

  defp coverage_ignore_line_range({line, line_number}, state) do
    state =
      if state.test_coverage_depth > 0 and state.ignore_start == nil and opens_ignore_modules?(line) do
        %{state | ignore_start: line_number}
      else
        state
      end

    state = track_test_coverage_depth(state, line)

    cond do
      state.ignore_start != nil and closes_list?(line) ->
        %{state | ignore_start: nil, ranges: [{state.ignore_start, line_number} | state.ranges]}

      state.test_coverage_depth == 0 ->
        %{state | ignore_start: nil}

      true ->
        state
    end
  end

  defp track_test_coverage_depth(state, line) do
    depth =
      case state.test_coverage_depth do
        0 ->
          if String.match?(line, ~r/\btest_coverage:\s*\[/), do: bracket_delta(line), else: 0

        depth ->
          depth + bracket_delta(line)
      end

    %{state | test_coverage_depth: max(depth, 0)}
  end

  defp bracket_delta(content) do
    uncommented = content |> String.split("#", parts: 2) |> hd()
    length(Regex.scan(~r/\[/, uncommented)) - length(Regex.scan(~r/\]/, uncommented))
  end

  defp line_in_ranges?(line_number, ranges) do
    Enum.any?(ranges, fn {first, last} -> line_number >= first and line_number <= last end)
  end

  defp added_line?(line), do: String.starts_with?(line, "+") and not String.starts_with?(line, "+++")
  defp deleted_line?(line), do: String.starts_with?(line, "-")

  defp opens_ignore_modules?(line) do
    patch_line_content(line)
    |> String.match?(~r/\bignore_modules:\s*\[/)
  end

  defp closes_list?(line) do
    patch_line_content(line)
    |> String.match?(~r/^\s*\]/)
  end

  defp added_module_from_line("+" <> rest) do
    case Regex.run(~r/^\s*([A-Z][A-Za-z0-9_.]*)\s*,?\s*(?:#.*)?$/, rest) do
      [_, module] -> module
      _ -> nil
    end
  end

  defp added_module_from_line(_line), do: nil

  defp patch_line_content("+" <> rest), do: rest
  defp patch_line_content("-" <> rest), do: rest
  defp patch_line_content(" " <> rest), do: rest
  defp patch_line_content(line), do: line

  defp merge_base_sha(owner, repo, base_ref, head_sha, github_client) do
    encoded_base_ref = URI.encode(base_ref, &URI.char_unreserved?/1)
    compare_url = "#{@github_api}/repos/#{owner}/#{repo}/compare/#{encoded_base_ref}...#{head_sha}"

    with {:ok, comparison} <- github_json(github_client, compare_url) do
      required_string(comparison, ["merge_base_commit", "sha"], :review_readiness_missing_pr_merge_base_sha)
    end
  end

  defp stale_base_ready?(owner, repo, base_ref, merge_base_sha, pr_files, github_client) do
    compare_url = "#{@github_api}/repos/#{owner}/#{repo}/compare/#{merge_base_sha}...#{URI.encode(base_ref, &URI.char_unreserved?/1)}"

    with {:ok, comparison} <- github_json(github_client, compare_url) do
      stale_base_overlap(comparison, pr_files)
    end
  end

  defp stale_base_overlap(%{"ahead_by" => ahead_by, "files" => base_files}, pr_files)
       when is_integer(ahead_by) and ahead_by > 0 and is_list(base_files) do
    pr_filenames = changed_filenames(pr_files)
    base_filenames = changed_filenames(base_files)
    overlap = MapSet.intersection(pr_filenames, base_filenames)

    if MapSet.size(overlap) == 0 do
      :ok
    else
      {:error, {:review_readiness_stale_base_overlap, Enum.sort(overlap)}}
    end
  end

  defp stale_base_overlap(_comparison, _pr_files), do: :ok

  defp changed_filenames(files) do
    Enum.reduce(files, MapSet.new(), fn file, acc ->
      acc
      |> maybe_put_filename(Map.get(file, "filename"))
      |> maybe_put_filename(Map.get(file, "previous_filename"))
    end)
  end

  defp maybe_put_filename(filenames, filename) when is_binary(filename), do: MapSet.put(filenames, filename)
  defp maybe_put_filename(filenames, _filename), do: filenames

  defp required_string(payload, path, error) do
    case get_in(payload, path) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp required_check_specs(%{"checks" => checks} = payload) when is_list(checks) and checks != [] do
    specs =
      checks
      |> Enum.map(&required_check_spec/1)
      |> Enum.reject(&is_nil/1)

    if specs == [] do
      required_context_specs(payload)
    else
      {:ok, specs}
    end
  end

  defp required_check_specs(payload), do: required_context_specs(payload)

  defp required_check_spec(%{"context" => context} = check) when is_binary(context) do
    context = String.trim(context)

    if context == "" do
      nil
    else
      %{context: context, app_id: normalize_app_id(Map.get(check, "app_id"))}
    end
  end

  defp required_check_spec(_check), do: nil

  defp required_context_specs(%{"contexts" => contexts}) when is_list(contexts) do
    contexts
    |> Enum.map(&required_context_spec/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> {:error, :review_readiness_required_checks_missing}
      specs -> {:ok, specs}
    end
  end

  defp required_context_specs(_payload), do: {:error, :review_readiness_required_checks_unverifiable}

  defp required_context_spec(context) when is_binary(context) do
    context
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> %{context: trimmed, app_id: nil}
    end
  end

  defp required_context_spec(_context), do: nil

  defp configured_required_checks_or_error(reason) do
    configured_required_checks()
    |> Enum.map(&%{context: &1, app_id: nil})
    |> case do
      [] -> {:error, reason}
      specs -> {:ok, specs}
    end
  end

  defp configured_required_checks do
    Config.settings!().codex.review_readiness_required_checks
  rescue
    _ -> []
  end

  defp verify_contexts(required_checks, statuses, check_runs) do
    status_contexts = latest_status_contexts(statuses)
    check_runs_by_name = latest_check_runs_by_name(check_runs)

    failures =
      Enum.flat_map(required_checks, &check_failure(&1, status_contexts, check_runs_by_name))

    case failures do
      [] -> :ok
      failures -> {:error, {:review_readiness_required_checks_not_passing, failures}}
    end
  end

  defp check_failure(%{context: context, app_id: nil}, status_contexts, check_runs_by_name) do
    latest_check = latest_check_run(check_runs_by_name, context, nil)

    cond do
      Map.get(status_contexts, context) in @passing_status_states ->
        []

      check_run_conclusion(latest_check) in @passing_check_conclusions ->
        []

      Map.has_key?(status_contexts, context) ->
        [{context, {:status, Map.get(status_contexts, context)}}]

      latest_check != nil ->
        [{context, {:check, check_run_conclusion(latest_check)}}]

      true ->
        [{context, :missing}]
    end
  end

  defp check_failure(%{context: context, app_id: app_id}, _status_contexts, check_runs_by_name) do
    latest_check = latest_check_run(check_runs_by_name, context, app_id)

    cond do
      check_run_conclusion(latest_check) in @passing_check_conclusions ->
        []

      latest_check != nil ->
        [{context, {:check, check_run_conclusion(latest_check)}}]

      Map.has_key?(check_runs_by_name, context) ->
        [{context, {:check, "app_mismatch"}}]

      true ->
        [{context, :missing}]
    end
  end

  defp latest_status_contexts(%{"statuses" => statuses}) when is_list(statuses) do
    Enum.reduce(statuses, %{}, fn status, acc ->
      with context when is_binary(context) <- Map.get(status, "context"),
           state when is_binary(state) <- Map.get(status, "state") do
        Map.put_new(acc, context, state)
      else
        _ -> acc
      end
    end)
  end

  defp latest_status_contexts(_statuses), do: %{}

  defp latest_check_runs_by_name(%{"check_runs" => runs}) when is_list(runs) do
    Enum.reduce(runs, %{}, fn run, acc ->
      case Map.get(run, "name") do
        name when is_binary(name) ->
          Map.update(acc, name, [run], &(&1 ++ [run]))

        _ ->
          acc
      end
    end)
  end

  defp latest_check_runs_by_name(_runs), do: %{}

  defp latest_check_run(check_runs_by_name, context, nil) do
    check_runs_by_name
    |> Map.get(context, [])
    |> List.first()
  end

  defp latest_check_run(check_runs_by_name, context, app_id) do
    check_runs_by_name
    |> Map.get(context, [])
    |> Enum.find(&(check_run_app_id(&1) == app_id))
  end

  defp check_run_conclusion(nil), do: "missing"

  defp check_run_conclusion(run) do
    case {Map.get(run, "status"), Map.get(run, "conclusion")} do
      {"completed", value} when is_binary(value) -> value
      {status, _} when is_binary(status) -> status
      _ -> "missing"
    end
  end

  defp check_run_app_id(%{"app" => %{"id" => app_id}}), do: normalize_app_id(app_id)
  defp check_run_app_id(_run), do: nil

  defp normalize_app_id(app_id) when is_integer(app_id), do: Integer.to_string(app_id)

  defp normalize_app_id(app_id) when is_binary(app_id) do
    case String.trim(app_id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_app_id(_app_id), do: nil

  defp reject(issue_or_id, reason, linear_client) do
    issue = if is_map(issue_or_id), do: issue_or_id, else: %{"id" => issue_or_id}
    message = rejection_message(reason)

    if is_binary(issue["id"]) do
      _ = upsert_workpad(issue, readiness_note(issue, "In Review transition rejected", message), linear_client)
    end

    {:error,
     {:review_readiness_rejected,
      %{
        "error" => %{
          "code" => "review_readiness_rejected",
          "message" => "Linear In Review transition rejected: #{message}",
          "reason" => inspect(reason)
        }
      }}}
  end

  defp upsert_workpad(issue, note, linear_client) do
    case workpad_comment(issue) do
      %{"id" => comment_id, "body" => body} when is_binary(comment_id) and is_binary(body) ->
        linear_client.(@update_comment_mutation, %{"commentId" => comment_id, "body" => append_workpad_note(body, note)}, [])
        |> comment_result("commentUpdate")

      _ ->
        linear_client.(@create_comment_mutation, %{"issueId" => issue["id"], "body" => "## Codex Workpad\n\n" <> note}, [])
        |> comment_result("commentCreate")
    end
  end

  defp workpad_comment(issue) do
    issue
    |> get_in(["comments", "nodes"])
    |> case do
      comments when is_list(comments) ->
        Enum.find(comments, fn
          %{"body" => body} when is_binary(body) -> String.starts_with?(String.trim_leading(body), "## Codex Workpad")
          _ -> false
        end)

      _ ->
        nil
    end
  end

  defp append_workpad_note(body, note) do
    String.trim_trailing(body) <> "\n\n" <> note
  end

  defp comment_result({:ok, %{"data" => data}}, field) when is_map(data) do
    if get_in(data, [field, "success"]) == true, do: :ok, else: {:error, :workpad_update_failed}
  end

  defp comment_result({:ok, _payload}, _field), do: {:error, :workpad_update_failed}
  defp comment_result({:error, reason}, _field), do: {:error, reason}

  defp readiness_note(issue, heading, detail) do
    identifier = Map.get(issue, "identifier") || Map.get(issue, "id") || "unknown issue"

    [
      "### Review readiness",
      "",
      "- Issue: #{identifier}",
      "- Decision: #{heading}",
      "- Detail: #{detail}",
      "- Recorded at: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}"
    ]
    |> Enum.join("\n")
  end

  defp rejection_message(:review_readiness_missing_issue_id), do: "the issue id could not be determined."
  defp rejection_message(:review_readiness_missing_state_id), do: "the target state id could not be determined."
  defp rejection_message(:review_readiness_multiple_issue_updates), do: "multiple issueUpdate mutations were found; review readiness can only verify one state transition at a time."
  defp rejection_message(:review_readiness_issue_unverifiable), do: "Linear issue context could not be verified."
  defp rejection_message(:review_readiness_destination_state_unverifiable), do: "the destination state could not be verified."
  defp rejection_message(:review_readiness_issue_update_unverifiable), do: "the Linear issueUpdate mutation could not be verified."
  defp rejection_message(:review_readiness_missing_linked_pull_request), do: "no linked GitHub pull request was found."
  defp rejection_message(:review_readiness_repository_unconfigured), do: "no trusted GitHub repository is configured for review readiness."
  defp rejection_message(:review_readiness_issue_identifier_missing), do: "the Linear issue identifier could not be verified."
  defp rejection_message(:review_readiness_pr_head_repository_unverifiable), do: "the linked PR head repository could not be verified."
  defp rejection_message(:review_readiness_pr_branch_unverifiable), do: "the linked PR head branch could not be verified."
  defp rejection_message(:review_readiness_required_checks_missing), do: "no required GitHub checks are configured or visible."
  defp rejection_message(:review_readiness_required_checks_unverifiable), do: "required GitHub checks could not be verified."
  defp rejection_message(:review_readiness_missing_pr_head_sha), do: "the linked PR head SHA could not be verified."
  defp rejection_message(:review_readiness_missing_pr_base_ref), do: "the linked PR base branch could not be verified."
  defp rejection_message(:review_readiness_missing_pr_merge_base_sha), do: "the linked PR merge-base SHA could not be verified."
  defp rejection_message(:review_readiness_github_content_unreadable), do: "GitHub file content could not be decoded for review readiness."

  defp rejection_message(:review_readiness_agent_override_not_allowed),
    do: "manager override cannot be authorized by an agent tool call; a manager must move the issue outside the agent session and leave an audit note."

  defp rejection_message({:review_readiness_missing_variable, variable}),
    do: "the GraphQL variable `$#{variable}` was missing or blank."

  defp rejection_message({:review_readiness_issue_unverifiable, reason}),
    do: "Linear issue context could not be verified: #{inspect(reason)}."

  defp rejection_message({:review_readiness_github_unverifiable, reason}),
    do: "GitHub readiness could not be verified: #{inspect(reason)}."

  defp rejection_message({:review_readiness_github_unverifiable, status, body}),
    do: "GitHub readiness could not be verified: HTTP #{status} #{body}."

  defp rejection_message({:review_readiness_untrusted_repository, repository}),
    do: "linked PR repository #{repository} is not the configured trusted repository."

  defp rejection_message({:review_readiness_untrusted_head_repository, repository}),
    do: "linked PR head repository #{repository} is not the configured trusted repository."

  defp rejection_message({:review_readiness_pr_branch_mismatch, head_ref, identifier}),
    do: "linked PR branch #{head_ref} does not match Linear issue #{identifier}."

  defp rejection_message({:review_readiness_required_checks_not_passing, failures}),
    do: "required GitHub checks are not passing: #{format_failures(failures)}."

  defp rejection_message({:review_readiness_pr_file_list_too_large, changed_files}),
    do: "the linked PR changes #{changed_files} files; review readiness only verifies the first 100 GitHub PR files. Split the PR or get manager review outside the agent session."

  defp rejection_message({:review_readiness_coverage_ignore_changed_modules, modules}),
    do: "coverage ignore additions include modules changed in this PR: #{Enum.join(modules, ", ")}. Remove the ignore entry or get a manager to audit and move the issue outside the agent session."

  defp rejection_message({:review_readiness_stale_base_overlap, filenames}),
    do: "the PR base is stale and current base branch changes overlap PR files: #{Enum.join(filenames, ", ")}. Merge current base, resolve the overlap, and rerun validation."

  defp format_failures(failures) do
    Enum.map_join(failures, ", ", fn
      {context, :missing} -> "#{context}=missing"
      {context, {kind, state}} -> "#{context}=#{kind}:#{state}"
    end)
  end

  defp summarize_body(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize_body(body), do: body |> inspect(limit: 20, printable_limit: 200)

  defp maybe_add_github_token(headers) do
    case System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN") do
      token when is_binary(token) and token != "" -> [{"Authorization", "Bearer #{token}"} | headers]
      _ -> headers
    end
  end

  defp normalize(value) do
    value
    |> String.trim()
    |> String.downcase()
  end
end
