defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Codex.RolloutIndex
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.LogFile.Formatter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          resolve_graphql_result(result, query, variables)

        _ ->
          Process.get({__MODULE__, :graphql_result})
          |> resolve_graphql_result(query, variables)
      end
    end

    defp resolve_graphql_result(result, query, variables) when is_function(result, 2) do
      result.(query, variables)
    end

    defp resolve_graphql_result(result, _query, _variables), do: result
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call({:steer_worker, issue_identifier, message, session_id}, _from, state) do
      if parent = Keyword.get(state, :parent) do
        send(parent, {:steer_worker_called, issue_identifier, message, session_id})
      end

      {:reply,
       {:ok,
        %{
          issue_identifier: issue_identifier,
          issue_id: "issue-http",
          session_id: session_id,
          queued_at: DateTime.utc_now()
        }}, state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert {:ok, %{id: "memory-issue-1", owner: "memory"}} = SymphonyElixir.Tracker.acquire_issue_claim(issue)
    assert :ok = SymphonyElixir.Tracker.recover_stale_issue_claim(issue)
    assert :ok = SymphonyElixir.Tracker.release_issue_claim("issue-1")
    assert :ok = Memory.release_issue_claim("issue-1")
    assert {:error, :invalid_issue_claim} = Memory.acquire_issue_claim(%{})
    assert {:error, :invalid_issue_claim} = Memory.recover_stale_issue_claim(%{})
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_claim_acquired, "issue-1", "MT-1", %{owner: "memory"}}
    assert_receive {:memory_tracker_claim_recovery_checked, "issue-1", "MT-1"}
    assert_receive {:memory_tracker_claim_released, "issue-1"}
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")
    flush_graphql_messages()

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => []}}}
           }
         }}
      ]
    )

    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Blocked")
    assert_receive {:graphql_called, _blocked_lookup_query, %{issueId: "issue-1", stateName: "Blocked"}}
    refute_receive {:graphql_called, _update_issue_query, %{stateId: _missing_state_id}}

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "linear adapter acquires visible claim when this worker owns the oldest active lease" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    now = DateTime.add(DateTime.utc_now(), -60, :second)

    Process.put({FakeLinearClient, :graphql_result}, fn query, variables ->
      cond do
        String.contains?(query, "commentCreate") ->
          Process.put(:claim_body, variables.body)

          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{
                 "success" => true,
                 "comment" => %{"id" => "claim-own", "createdAt" => DateTime.to_iso8601(now)}
               }
             }
           }}

        String.contains?(query, "SymphonyIssueClaimComments") ->
          claim_body = Process.get(:claim_body)

          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" =>
                     if claim_body do
                       [
                         %{
                           "id" => "claim-own",
                           "body" => claim_body,
                           "createdAt" => DateTime.to_iso8601(now)
                         }
                       ]
                     else
                       []
                     end,
                   "pageInfo" => %{"hasNextPage" => false}
                 }
               }
             }
           }}
      end
    end)

    assert {:ok, %{id: "claim-own", owner: owner, expires_at: %DateTime{}}} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    assert is_binary(owner)
  end

  test "linear adapter rejects dispatch when another unexpired lease is older" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    older = DateTime.add(DateTime.utc_now(), -60, :second)
    newer = DateTime.add(older, 1, :second)
    expires_at = DateTime.add(older, 4, :hour)

    Process.put({FakeLinearClient, :graphql_result}, fn query, variables ->
      cond do
        String.contains?(query, "commentCreate") ->
          Process.put(:claim_body, variables.body)

          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{
                 "success" => true,
                 "comment" => %{"id" => "claim-own", "createdAt" => DateTime.to_iso8601(newer)}
               }
             }
           }}

        String.contains?(query, "SymphonyIssueClaimComments") ->
          competitor_body = signed_claim_body("ALB-CLAIM", "other-worker", "older-token", older, expires_at)

          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" => [
                     %{"id" => "claim-other", "body" => competitor_body, "createdAt" => DateTime.to_iso8601(older)},
                     %{"id" => "claim-own", "body" => Process.get(:claim_body), "createdAt" => DateTime.to_iso8601(newer)}
                   ]
                 }
               }
             }
           }}
      end
    end)

    assert {:error, {:issue_claimed, %{id: "claim-other", owner: "other-worker"}}} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    refute Process.get(:claim_body)
  end

  test "linear adapter recovers same-host stale claim when owner pid is not alive" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :local_os_pid_alive?, fn "424242" -> false end)

    claimed_at = DateTime.add(DateTime.utc_now(), -60, :second)
    expires_at = DateTime.add(claimed_at, 4, :hour)
    owner = "#{test_hostname()}:424242:#PID<0.1.0>:1"
    claim_body = signed_claim_body("ALB-CLAIM", owner, "stale-token", claimed_at, expires_at)

    Process.put({FakeLinearClient, :graphql_results}, [
      claim_comments([%{"id" => "claim-stale", "body" => claim_body, "createdAt" => DateTime.to_iso8601(claimed_at)}]),
      fn query, variables ->
        assert String.contains?(query, "commentCreate")
        assert variables.issueId == "issue-claim"
        assert variables.body =~ "## Symphony Claim Release"
        assert variables.body =~ "claim_id: claim-stale"
        assert variables.body =~ "owner: #{owner}"
        assert variables.body =~ "token: stale-token"

        {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
      end,
      empty_claim_comments(),
      fn query, variables ->
        assert String.contains?(query, "commentCreate")
        Process.put(:claim_body, variables.body)

        {:ok,
         %{
           "data" => %{
             "commentCreate" => %{
               "success" => true,
               "comment" => %{"id" => "claim-own", "createdAt" => DateTime.to_iso8601(DateTime.utc_now())}
             }
           }
         }}
      end,
      fn query, _variables ->
        assert String.contains?(query, "SymphonyIssueClaimComments")

        claim_body = Process.get(:claim_body)

        claim_comments([
          %{"id" => "claim-own", "body" => claim_body, "createdAt" => DateTime.to_iso8601(DateTime.utc_now())}
        ])
      end
    ])

    assert :ok = Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
    assert {:ok, %{id: "claim-own"}} = Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter preserves same-host claim when owner pid is still alive" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :local_os_pid_alive?, fn "31337" -> true end)

    claimed_at = DateTime.add(DateTime.utc_now(), -60, :second)
    expires_at = DateTime.add(claimed_at, 4, :hour)
    owner = "#{test_hostname()}:31337:#PID<0.1.0>:1"
    claim_body = signed_claim_body("ALB-CLAIM", owner, "live-token", claimed_at, expires_at)

    Process.put(
      {FakeLinearClient, :graphql_result},
      claim_comments([%{"id" => "claim-live", "body" => claim_body, "createdAt" => DateTime.to_iso8601(claimed_at)}])
    )

    assert :ok = Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    assert {:error, {:issue_claimed, %{id: "claim-live", owner: ^owner}}} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter default pid probe releases missing same-host owner" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.delete_env(:symphony_elixir, :local_os_pid_alive?)

    claimed_at = DateTime.add(DateTime.utc_now(), -60, :second)
    expires_at = DateTime.add(claimed_at, 4, :hour)
    owner = "#{test_hostname()}:999999:#PID<0.1.0>:1"
    claim_body = signed_claim_body("ALB-CLAIM", owner, "missing-pid-token", claimed_at, expires_at)

    Application.put_env(:symphony_elixir, :tasklist_lookup, fn "tasklist" -> nil end)

    Process.put({FakeLinearClient, :graphql_results}, [
      claim_comments([%{"id" => "claim-missing-tasklist", "body" => claim_body, "createdAt" => DateTime.to_iso8601(claimed_at)}]),
      fn query, variables ->
        assert String.contains?(query, "commentCreate")
        assert variables.body =~ "claim_id: claim-missing-tasklist"

        {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
      end
    ])

    assert :ok = Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    Application.put_env(:symphony_elixir, :tasklist_lookup, fn "tasklist" -> "tasklist.exe" end)
    Application.put_env(:symphony_elixir, :tasklist_cmd, fn "tasklist.exe", _args, _opts -> {"", 1} end)

    Process.put({FakeLinearClient, :graphql_results}, [
      claim_comments([%{"id" => "claim-tasklist-error", "body" => claim_body, "createdAt" => DateTime.to_iso8601(claimed_at)}]),
      fn query, variables ->
        assert String.contains?(query, "commentCreate")
        assert variables.body =~ "claim_id: claim-tasklist-error"

        {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
      end
    ])

    assert :ok = Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    Application.put_env(:symphony_elixir, :tasklist_cmd, fn "tasklist.exe", _args, _opts ->
      {~s("Image Name","PID","Session Name"\n"beam.smp.exe","123456","Console"), 0}
    end)

    Process.put({FakeLinearClient, :graphql_results}, [
      claim_comments([%{"id" => "claim-missing-pid", "body" => claim_body, "createdAt" => DateTime.to_iso8601(claimed_at)}]),
      fn query, variables ->
        assert String.contains?(query, "commentCreate")
        assert variables.body =~ "claim_id: claim-missing-pid"
        assert variables.body =~ "token: missing-pid-token"

        {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
      end
    ])

    assert :ok = Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter default pid probe preserves listed same-host owner" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.delete_env(:symphony_elixir, :local_os_pid_alive?)
    Application.put_env(:symphony_elixir, :tasklist_lookup, fn "tasklist" -> "tasklist.exe" end)

    Application.put_env(:symphony_elixir, :tasklist_cmd, fn "tasklist.exe", _args, _opts ->
      {~s("Image Name","PID","Session Name"\n"beam.smp.exe","31337","Console"), 0}
    end)

    claimed_at = DateTime.add(DateTime.utc_now(), -60, :second)
    expires_at = DateTime.add(claimed_at, 4, :hour)
    owner = "#{test_hostname()}:31337:#PID<0.1.0>:1"
    claim_body = signed_claim_body("ALB-CLAIM", owner, "listed-pid-token", claimed_at, expires_at)

    Process.put(
      {FakeLinearClient, :graphql_result},
      claim_comments([%{"id" => "claim-listed-pid", "body" => claim_body, "createdAt" => DateTime.to_iso8601(claimed_at)}])
    )

    assert :ok = Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    assert {:error, {:issue_claimed, %{id: "claim-listed-pid", owner: ^owner}}} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter stops recovery when stale claim release fails" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :local_os_pid_alive?, fn "424242" -> false end)

    claimed_at = DateTime.add(DateTime.utc_now(), -60, :second)
    expires_at = DateTime.add(claimed_at, 4, :hour)
    owner = "#{test_hostname()}:424242:#PID<0.1.0>:1"
    claim_body = signed_claim_body("ALB-CLAIM", owner, "stale-token", claimed_at, expires_at)

    Process.put({FakeLinearClient, :graphql_results}, [
      claim_comments([%{"id" => "claim-stale", "body" => claim_body, "createdAt" => DateTime.to_iso8601(claimed_at)}]),
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    ])

    assert {:error, :claim_release_failed} =
             Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter preserves other-host active claim during recovery" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :local_os_pid_alive?, fn _pid -> flunk("other-host pid must not be inspected") end)

    claimed_at = DateTime.add(DateTime.utc_now(), -60, :second)
    expires_at = DateTime.add(claimed_at, 4, :hour)
    owner = "other-host:424242:#PID<0.1.0>:1"
    claim_body = signed_claim_body("ALB-CLAIM", owner, "other-token", claimed_at, expires_at)

    Process.put(
      {FakeLinearClient, :graphql_result},
      claim_comments([%{"id" => "claim-other", "body" => claim_body, "createdAt" => DateTime.to_iso8601(claimed_at)}])
    )

    assert :ok = Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    assert {:error, {:issue_claimed, %{id: "claim-other", owner: ^owner}}} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter preserves malformed-owner active claim during recovery" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :local_os_pid_alive?, fn _pid -> flunk("malformed owner pid must not be inspected") end)

    claimed_at = DateTime.add(DateTime.utc_now(), -60, :second)
    expires_at = DateTime.add(claimed_at, 4, :hour)
    owner = "#{test_hostname()}:not-a-pid:#PID<0.1.0>:1"
    claim_body = signed_claim_body("ALB-CLAIM", owner, "malformed-token", claimed_at, expires_at)

    Process.put(
      {FakeLinearClient, :graphql_result},
      claim_comments([%{"id" => "claim-malformed", "body" => claim_body, "createdAt" => DateTime.to_iso8601(claimed_at)}])
    )

    assert :ok = Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    assert {:error, {:issue_claimed, %{id: "claim-malformed", owner: ^owner}}} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    owner = "malformed-owner"
    claim_body = signed_claim_body("ALB-CLAIM", owner, "malformed-token-2", claimed_at, expires_at)

    Process.put(
      {FakeLinearClient, :graphql_result},
      claim_comments([%{"id" => "claim-malformed-2", "body" => claim_body, "createdAt" => DateTime.to_iso8601(claimed_at)}])
    )

    assert :ok = Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    assert {:error, {:issue_claimed, %{id: "claim-malformed-2", owner: ^owner}}} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter ignores unsigned spoofed claims before dispatch" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    older = DateTime.add(DateTime.utc_now(), -60, :second)
    newer = DateTime.add(older, 1, :second)
    expires_at = DateTime.add(older, 4, :hour)

    Process.put({FakeLinearClient, :graphql_result}, fn query, variables ->
      cond do
        String.contains?(query, "commentCreate") ->
          Process.put(:claim_body, variables.body)

          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{
                 "success" => true,
                 "comment" => %{"id" => "claim-own", "createdAt" => DateTime.to_iso8601(newer)}
               }
             }
           }}

        String.contains?(query, "SymphonyIssueClaimComments") ->
          spoofed_body =
            [
              "## Symphony Claim Lease",
              "",
              "owner: spoofed-worker",
              "token: copied-token",
              "issue: ALB-CLAIM",
              "claimed_at: #{DateTime.to_iso8601(older)}",
              "expires_at: #{DateTime.to_iso8601(expires_at)}"
            ]
            |> Enum.join("\n")

          claim_body = Process.get(:claim_body)

          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" =>
                     [%{"id" => "claim-spoofed", "body" => spoofed_body, "createdAt" => DateTime.to_iso8601(older)}] ++
                       if claim_body do
                         [%{"id" => "claim-own", "body" => claim_body, "createdAt" => DateTime.to_iso8601(newer)}]
                       else
                         []
                       end,
                   "pageInfo" => %{"hasNextPage" => false}
                 }
               }
             }
           }}
      end
    end)

    assert {:ok, %{id: "claim-own"}} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter ignores unsigned spoofed releases for visible tokens" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    claimed_at = DateTime.add(DateTime.utc_now(), -60, :second)
    released_at = DateTime.add(claimed_at, 10, :second)
    expires_at = DateTime.add(claimed_at, 4, :hour)
    claim_body = signed_claim_body("ALB-CLAIM", "other-worker", "visible-token", claimed_at, expires_at)

    spoofed_release =
      [
        "## Symphony Claim Release",
        "",
        "claim_id: claim-other",
        "owner: other-worker",
        "token: visible-token",
        "released_at: #{DateTime.to_iso8601(released_at)}"
      ]
      |> Enum.join("\n")

    Process.put({FakeLinearClient, :graphql_result}, fn query, _variables ->
      assert String.contains?(query, "SymphonyIssueClaimComments")

      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => [
                 %{"id" => "claim-other", "body" => claim_body, "createdAt" => DateTime.to_iso8601(claimed_at)},
                 %{"id" => "release-spoofed", "body" => spoofed_release, "createdAt" => DateTime.to_iso8601(released_at)}
               ],
               "pageInfo" => %{"hasNextPage" => false}
             }
           }
         }
       }}
    end)

    assert {:error, {:issue_claimed, %{id: "claim-other", owner: "other-worker"}}} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter releases its claim when verification cannot read claim comments" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    now = DateTime.utc_now()

    Process.put({FakeLinearClient, :graphql_results}, [
      empty_claim_comments(),
      {:ok,
       %{
         "data" => %{
           "commentCreate" => %{
             "success" => true,
             "comment" => %{"id" => "claim-own", "createdAt" => DateTime.to_iso8601(now)}
           }
         }
       }},
      {:error, :linear_timeout},
      fn query, variables ->
        assert String.contains?(query, "commentCreate")
        assert variables.body =~ "## Symphony Claim Release"
        assert variables.body =~ "token:"

        {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
      end
    ])

    assert {:error, :linear_timeout} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter handles claim and release error branches" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:error, :invalid_issue_claim} = Adapter.acquire_issue_claim(%{})
    assert {:error, :invalid_issue_claim} = Adapter.recover_stale_issue_claim(%{})
    assert :ok = Adapter.release_issue_claim("issue-claim")
    assert :ok = Adapter.release_issue_claim("issue-claim", %{})
    assert :ok = Adapter.release_issue_claim("issue-claim", :invalid_claim)

    Process.put({FakeLinearClient, :graphql_result}, empty_claim_comments())
    assert :ok = Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    Process.put({FakeLinearClient, :graphql_result}, {:error, :recovery_timeout})

    assert {:error, :recovery_timeout} =
             Adapter.recover_stale_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :claim_release_failed} =
             Adapter.release_issue_claim("issue-claim", %{id: "claim-1", owner: "worker", token: "token"})

    Process.put({FakeLinearClient, :graphql_result}, {:error, :release_timeout})

    assert {:error, :release_timeout} =
             Adapter.release_issue_claim("issue-claim", %{id: "claim-1", owner: "worker", token: "token"})

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)

    assert {:error, :claim_release_failed} =
             Adapter.release_issue_claim("issue-claim", %{id: "claim-1", owner: "worker", token: "token"})

    Process.put({FakeLinearClient, :graphql_results}, [
      empty_claim_comments(),
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    ])

    assert {:error, :claim_create_failed} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    Process.put({FakeLinearClient, :graphql_results}, [empty_claim_comments(), {:error, :create_timeout}])

    assert {:error, :create_timeout} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    Process.put({FakeLinearClient, :graphql_results}, [empty_claim_comments(), :unexpected])

    assert {:error, :claim_create_failed} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    Process.put({FakeLinearClient, :graphql_result}, {:error, :preflight_timeout})

    assert {:error, :preflight_timeout} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter can sign test lease bodies without a configured api token" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    System.delete_env("LINEAR_API_KEY")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    body =
      signed_claim_body(
        "ALB-CLAIM",
        "worker",
        "token",
        ~U[2026-05-02 00:00:00Z],
        ~U[2026-05-02 04:00:00Z]
      )

    assert body =~ "signature:"
  end

  test "linear adapter ignores malformed claim comments and releases invisible claims" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    now = DateTime.utc_now()

    malformed_comments = malformed_claim_comments()

    Process.put({FakeLinearClient, :graphql_results}, [
      malformed_comments,
      {:ok,
       %{
         "data" => %{
           "commentCreate" => %{
             "success" => true,
             "comment" => %{"id" => "claim-own", "createdAt" => DateTime.to_iso8601(now)}
           }
         }
       }},
      malformed_comments,
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    ])

    assert {:error, :claim_not_visible} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    Process.put({FakeLinearClient, :graphql_results}, [
      empty_claim_comments(),
      {:ok,
       %{
         "data" => %{
           "commentCreate" => %{
             "success" => true,
             "comment" => %{"id" => "claim-own", "createdAt" => DateTime.to_iso8601(now)}
           }
         }
       }},
      :unexpected,
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    ])

    assert {:error, :claim_comments_fetch_failed} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "linear adapter scans paginated claim comments before selecting the winner" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    older = DateTime.add(DateTime.utc_now(), -60, :second)
    newer = DateTime.add(older, 1, :second)
    expires_at = DateTime.add(older, 4, :hour)

    Process.put({FakeLinearClient, :graphql_result}, fn query, variables ->
      cond do
        String.contains?(query, "commentCreate") ->
          Process.put(:claim_body, variables.body)

          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{
                 "success" => true,
                 "comment" => %{"id" => "claim-own", "createdAt" => DateTime.to_iso8601(newer)}
               }
             }
           }}

        String.contains?(query, "SymphonyIssueClaimComments") and is_nil(variables.after) ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-1"}
                 }
               }
             }
           }}

        String.contains?(query, "SymphonyIssueClaimComments") and variables.after == "cursor-1" ->
          competitor_body = signed_claim_body("ALB-CLAIM", "other-worker", "older-token", older, expires_at)

          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" => [
                     %{"id" => "claim-other", "body" => competitor_body, "createdAt" => DateTime.to_iso8601(older)},
                     %{"id" => "claim-own", "body" => Process.get(:claim_body), "createdAt" => DateTime.to_iso8601(newer)}
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}
      end
    end)

    assert {:error, {:issue_claimed, %{id: "claim-other", owner: "other-worker"}}} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})

    refute Process.get(:claim_body)
  end

  test "linear adapter ignores released and expired claims when selecting the lease owner" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    expired_at = DateTime.add(DateTime.utc_now(), -30, :second)
    released_at = DateTime.add(expired_at, 10, :second)
    now = DateTime.add(expired_at, 30, :second)

    Process.put({FakeLinearClient, :graphql_result}, fn query, variables ->
      cond do
        String.contains?(query, "commentCreate") ->
          Process.put(:claim_body, variables.body)

          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{
                 "success" => true,
                 "comment" => %{"id" => "claim-own", "createdAt" => DateTime.to_iso8601(now)}
               }
             }
           }}

        String.contains?(query, "SymphonyIssueClaimComments") ->
          expired_body = signed_claim_body("ALB-CLAIM", "expired-worker", "expired-token", expired_at, expired_at)

          released_claim_body =
            signed_claim_body(
              "ALB-CLAIM",
              "released-worker",
              "released-token",
              expired_at,
              DateTime.add(expired_at, 4, :hour)
            )

          release_body = signed_release_body("claim-released", "released-worker", "released-token", released_at)
          claim_body = Process.get(:claim_body)

          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" =>
                     [
                       %{"id" => "claim-expired", "body" => expired_body, "createdAt" => DateTime.to_iso8601(expired_at)},
                       %{"id" => "claim-released", "body" => released_claim_body, "createdAt" => DateTime.to_iso8601(expired_at)},
                       %{"id" => "release-released", "body" => release_body, "createdAt" => DateTime.to_iso8601(released_at)}
                     ] ++
                       if claim_body do
                         [%{"id" => "claim-own", "body" => claim_body, "createdAt" => DateTime.to_iso8601(now)}]
                       else
                         []
                       end,
                   "pageInfo" => %{"hasNextPage" => false}
                 }
               }
             }
           }}
      end
    end)

    assert {:ok, %{id: "claim-own"}} =
             Adapter.acquire_issue_claim(%Issue{id: "issue-claim", identifier: "ALB-CLAIM"})
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)
    runtime_payload = Map.fetch!(state_payload, "runtime")

    assert %{
             "commit" => _commit,
             "workflow_path" => _workflow_path,
             "reload" => _reload
           } = runtime_payload

    assert Map.delete(state_payload, "runtime") == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "title" => "HTTP issue",
                 "url" => "https://example.org/issues/MT-HTTP",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "thread_id" => "thread-http",
                 "turn_id" => "turn-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "command_watchdog" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "error_kind" => "linear_transport",
                 "prior_error" => nil,
                 "prior_error_kind" => nil,
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "branch_name" => nil
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}},
             "workspace_cleanup" => nil
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "title" => "HTTP issue",
             "url" => "https://example.org/issues/MT-HTTP",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil,
               "branch" => nil
             },
             "pull_request" => nil,
             "checks" => nil,
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "thread_id" => "thread-http",
               "turn_id" => "turn-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "command_watchdog" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "timeline" => [
               %{
                 "at" => "2026-01-01T00:00:00Z",
                 "event" => "manager_steer_delivered",
                 "message" => "manager steer delivered: Keep the PR focused.",
                 "raw" => %{
                   "excerpt" => "%{\"id\" => 10123, \"result\" => %{\"turnId\" => \"turn-http\"}}",
                   "truncated?" => false
                 },
                 "session_id" => "thread-http",
                 "thread_id" => "thread-http",
                 "turn_id" => "turn-http"
               },
               %{
                 "at" => "2026-01-01T00:00:01Z",
                 "event" => "notification",
                 "message" => "item completed: agent message (msg-static)",
                 "raw" => %{
                   "excerpt" =>
                     "%{\n  \"method\" => \"item/completed\",\n  \"params\" => %{\n    \"item\" => %{\n      \"id\" => \"msg-static\",\n      \"text\" => \"Agent update complete.\",\n      \"type\" => \"agentMessage\"\n    }\n  }\n}",
                   "truncated?" => false
                 },
                 "session_id" => "thread-http",
                 "thread_id" => "thread-http",
                 "turn_id" => "turn-http"
               }
             ],
             "conversation" => [
               %{
                 "type" => "assistant",
                 "key" => "msg-static",
                 "at" => "2026-01-01T00:00:01Z",
                 "title" => "Agent",
                 "excerpt" => "Agent update complete.",
                 "truncated?" => false
               }
             ],
             "debug" => %{
               "payload_excerpt" => issue_payload["debug"]["payload_excerpt"],
               "payload_truncated?" => issue_payload["debug"]["payload_truncated?"]
             },
             "last_error" => nil,
             "tracked" => %{},
             "rollouts" => [],
             "current_rollout" => nil
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{
             "status" => "retrying",
             "retry" => %{"attempt" => 2, "error" => "boom", "error_kind" => "linear_transport"}
           } =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)

    assert %{"runtime" => %{"workflow_path" => _workflow_path}} =
             json_response(get(build_conn(), "/api/v1/runtime"), 200)

    assert json_response(post(build_conn(), "/api/v1/MT-HTTP/steer", %{}), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}
  end

  test "phoenix observability api queues guarded managed runtime reloads" do
    logs_root = Path.join(System.tmp_dir!(), "symphony-reload-test-#{System.unique_integer([:positive])}")

    try do
      repo_root = Path.join(logs_root, "repo")
      reload_script = Path.join([repo_root, "elixir", "scripts", "reload-windows-native.ps1"])
      File.mkdir_p!(Path.dirname(reload_script))
      File.write!(reload_script, "# test script\n")

      runtime_info = %{
        cwd: Path.join(repo_root, "elixir"),
        repo_root: repo_root,
        commit: "abc123456789",
        branch: nil,
        dirty?: false,
        workflow_path: Workflow.workflow_file_path(),
        logs_root: logs_root,
        pid_file: Path.join(logs_root, "symphony.pid.json"),
        port: 4011,
        os_pid: "999",
        started_at: "2026-01-01T00:00:00Z"
      }

      parent = self()
      Application.put_env(:symphony_elixir, :logs_root, logs_root)
      Application.put_env(:symphony_elixir, :pid_file, Path.join(logs_root, "symphony.pid.json"))
      Application.put_env(:symphony_elixir, :reload_runtime_info, runtime_info)
      Application.put_env(:symphony_elixir, :reload_id_fun, fn -> "reload-test" end)
      Application.put_env(:symphony_elixir, :reload_now_fun, fn -> ~U[2026-01-01 00:00:00Z] end)

      Application.put_env(:symphony_elixir, :reload_start_fun, fn payload ->
        send(parent, {:reload_started, payload})
        :ok
      end)

      running_orchestrator = Module.concat(__MODULE__, :ReloadRunningOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: running_orchestrator,
          snapshot: static_snapshot()
        )

      start_test_endpoint(orchestrator: running_orchestrator, snapshot_timeout_ms: 50, steer_token: "letmein")

      assert json_response(post(build_conn(), "/api/v1/runtime/reload", %{}), 403) == %{
               "error" => %{
                 "code" => "operator_token_required",
                 "message" => "Operator token is required"
               }
             }

      assert json_response(post(build_conn(), "/api/v1/runtime/reload", %{"operator_token" => "letmein"}), 409) == %{
               "error" => %{
                 "code" => "active_workers",
                 "message" => "Refusing reload while 1 worker(s) are active"
               }
             }

      refute_received {:reload_started, _payload}

      stop_supervised(SymphonyElixirWeb.Endpoint)
      idle_orchestrator = Module.concat(__MODULE__, :ReloadIdleOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: idle_orchestrator,
          snapshot: %{static_snapshot() | running: []}
        )

      start_test_endpoint(orchestrator: idle_orchestrator, snapshot_timeout_ms: 50, steer_token: "letmein")

      assert %{"reload" => %{"request_id" => "reload-test", "status" => "queued"}} =
               json_response(post(build_conn(), "/api/v1/runtime/reload", %{"operator_token" => "letmein"}), 202)

      assert_receive {:reload_started, %{request_id: "reload-test", target_ref: "origin/main"}}

      assert json_response(post(build_conn(), "/api/v1/runtime/reload", %{"operator_token" => "letmein"}), 409) == %{
               "error" => %{
                 "code" => "reload_in_progress",
                 "message" => "A managed reload is already queued or running"
               }
             }

      assert File.exists?(Path.join(logs_root, "reload/reload-test.json"))

      assert %{"runtime" => %{"reload" => %{"request_id" => "reload-test", "status" => "queued"}}} =
               json_response(get(build_conn(), "/api/v1/runtime"), 200)
    after
      File.rm_rf(logs_root)
    end
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/runtime/reload"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "agent worker status and timeline APIs return bounded coalesced redacted items" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerTimelineOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: worker_api_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    status_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/status"), 200)

    assert status_payload["issue"] == %{
             "id" => "issue-api",
             "identifier" => "MT-API",
             "state" => "In Progress",
             "title" => "Worker API issue",
             "url" => "https://example.org/issues/MT-API"
           }

    assert status_payload["session"] == %{
             "session_id" => "session-api",
             "thread_id" => "thread-api",
             "turn_count" => 3,
             "turn_id" => "turn-api"
           }

    assert status_payload["tokens"] == %{"input_tokens" => 10, "output_tokens" => 20, "total_tokens" => 30}
    assert status_payload["rate_limits"]["worker"]["primary"]["remaining"] == 42

    timeline_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/timeline?limit=2"), 200)

    assert timeline_payload["limit"] == 2
    assert timeline_payload["next_before"] == "3"
    assert [%{"type" => "tool_output"}, %{"type" => "manager_steer"}] = timeline_payload["items"]

    older_payload =
      json_response(
        get(build_conn(), "/api/v1/workers/MT-API/timeline?limit=5&before=#{timeline_payload["next_before"]}"),
        200
      )

    assert [
             %{
               "type" => "assistant_message",
               "body" => "Hello OPENAI_API_KEY=[REDACTED]",
               "truncated" => false
             }
           ] = older_payload["items"]

    debug_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/debug/events?limit=1"), 200)

    assert debug_payload["debug_only"] == true
    assert debug_payload["limit"] == 1
    refute inspect(debug_payload) =~ "sk-live-secret"
  end

  test "agent worker status and detail APIs project branch pull request and checks" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerPrProjectionOrchestrator)

    pr_projection = %{
      number: 110,
      url: "https://github.com/albert-zen/symphony-windows-native/pull/110",
      state: "OPEN",
      head_ref: "codex/ALB-63-rate-limit-card",
      head_sha: "03b64e1a85f678d000af4904e8fed084013efece",
      checks: [
        %{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"},
        %{name: "windows-native-test", status: "IN_PROGRESS", conclusion: nil}
      ]
    }

    snapshot =
      worker_api_snapshot(%{
        branch_name: "codex/ALB-63-rate-limit-card",
        pull_request: pr_projection
      })

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    status_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/status"), 200)

    assert status_payload["workspace"]["branch"] == "codex/ALB-63-rate-limit-card"

    assert status_payload["pull_request"] == %{
             "number" => 110,
             "url" => "https://github.com/albert-zen/symphony-windows-native/pull/110",
             "state" => "OPEN",
             "head_ref" => "codex/ALB-63-rate-limit-card",
             "head_sha" => "03b64e1a85f678d000af4904e8fed084013efece"
           }

    assert status_payload["checks"] == %{
             "summary" => "pending",
             "items" => [
               %{"name" => "make-all", "status" => "COMPLETED", "conclusion" => "SUCCESS", "details_url" => nil},
               %{"name" => "windows-native-test", "status" => "IN_PROGRESS", "conclusion" => nil, "details_url" => nil}
             ]
           }

    detail_payload = json_response(get(build_conn(), "/api/v1/MT-API"), 200)
    assert detail_payload["workspace"]["branch"] == "codex/ALB-63-rate-limit-card"
    assert detail_payload["pull_request"]["number"] == 110
    assert detail_payload["checks"]["summary"] == "pending"

    {:ok, _view, html} = live(build_conn(), "/workers/MT-API")
    assert html =~ "codex/ALB-63-rate-limit-card"
    assert html =~ "https://github.com/albert-zen/symphony-windows-native/pull/110"
    # Check summary ("pending") only appears in the API projection above —
    # the new LiveView shell surfaces the PR URL but not the rollup status.
  end

  test "agent worker status discovers branch and PR checks from workspace git and authenticated lookup" do
    workspace_root = Config.settings!().workspace.root
    workspace_path = Path.join(workspace_root, "MT-API-PR-#{System.unique_integer([:positive])}")
    branch = "codex/alb-66-worker-observability"
    test_pid = self()

    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)
    {_, 0} = System.cmd("git", ["init"], cd: workspace_path, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["checkout", "-b", branch], cd: workspace_path, stderr_to_stdout: true)

    previous_lookup = Application.get_env(:symphony_elixir, :worker_api_pr_lookup)

    Application.put_env(:symphony_elixir, :worker_api_pr_lookup, fn ^workspace_path, ^branch ->
      send(test_pid, {:worker_pr_lookup, workspace_path, branch})

      {:ok,
       %{
         "number" => 115,
         "url" => "https://github.com/albert-zen/symphony-windows-native/pull/115",
         "state" => "OPEN",
         "headRefName" => branch,
         "headRefOid" => "c39bc199cfc4efc6bb9edd258acecb2bc0f598f0",
         "statusCheckRollup" => [
           %{
             "name" => "make-all",
             "status" => "COMPLETED",
             "conclusion" => "FAILURE",
             "detailsUrl" => "https://example.org/check?token=sk-live-secret"
           },
           %{
             "context" => "legacy-status",
             "state" => "SUCCESS",
             "targetUrl" => "https://example.org/status"
           }
         ]
       }}
    end)

    on_exit(fn ->
      if previous_lookup do
        Application.put_env(:symphony_elixir, :worker_api_pr_lookup, previous_lookup)
      else
        Application.delete_env(:symphony_elixir, :worker_api_pr_lookup)
      end

      File.rm_rf!(workspace_path)
    end)

    snapshot = worker_api_snapshot(%{branch_name: nil, workspace_path: workspace_path})
    orchestrator_name = Module.concat(__MODULE__, :WorkerPrDiscoveryOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    status_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/status"), 200)

    assert_receive {:worker_pr_lookup, ^workspace_path, ^branch}
    assert status_payload["workspace"]["branch"] == branch
    assert status_payload["pull_request"]["number"] == 115
    assert status_payload["pull_request"]["head_ref"] == branch
    assert status_payload["checks"]["summary"] == "failing"

    assert [%{"details_url" => details_url}, %{"name" => "legacy-status", "status" => "COMPLETED", "conclusion" => "SUCCESS"}] =
             status_payload["checks"]["items"]

    refute details_url =~ "sk-live-secret"
  end

  test "agent worker status treats slow PR lookup as unavailable without blocking indefinitely" do
    workspace_root = Config.settings!().workspace.root
    workspace_path = Path.join(workspace_root, "MT-API-SLOW-PR-#{System.unique_integer([:positive])}")
    branch = "codex/alb-66-slow-lookup"

    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)
    {_, 0} = System.cmd("git", ["init"], cd: workspace_path, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["checkout", "-b", branch], cd: workspace_path, stderr_to_stdout: true)

    previous_lookup = Application.get_env(:symphony_elixir, :worker_api_pr_lookup)
    previous_timeout = Application.get_env(:symphony_elixir, :worker_api_pr_lookup_timeout_ms)

    Application.put_env(:symphony_elixir, :worker_api_pr_lookup, fn ^workspace_path, ^branch ->
      Process.sleep(100)
      {:ok, %{url: "https://example.org/too-late"}}
    end)

    Application.put_env(:symphony_elixir, :worker_api_pr_lookup_timeout_ms, 5)

    on_exit(fn ->
      if previous_lookup do
        Application.put_env(:symphony_elixir, :worker_api_pr_lookup, previous_lookup)
      else
        Application.delete_env(:symphony_elixir, :worker_api_pr_lookup)
      end

      if previous_timeout do
        Application.put_env(:symphony_elixir, :worker_api_pr_lookup_timeout_ms, previous_timeout)
      else
        Application.delete_env(:symphony_elixir, :worker_api_pr_lookup_timeout_ms)
      end

      File.rm_rf!(workspace_path)
    end)

    snapshot = worker_api_snapshot(%{branch_name: nil, workspace_path: workspace_path})
    orchestrator_name = Module.concat(__MODULE__, :WorkerSlowPrLookupOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    status_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/status"), 200)

    assert status_payload["workspace"]["branch"] == branch
    assert status_payload["pull_request"] == nil
    assert status_payload["checks"] == nil
  end

  test "agent worker status handles PR lookup failures as unavailable" do
    workspace_root = Config.settings!().workspace.root
    workspace_path = Path.join(workspace_root, "MT-API-RAISE-PR-#{System.unique_integer([:positive])}")
    branch = "codex/alb-66-lookup-failure"

    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)
    {_, 0} = System.cmd("git", ["init"], cd: workspace_path, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["checkout", "-b", branch], cd: workspace_path, stderr_to_stdout: true)

    previous_lookup = Application.get_env(:symphony_elixir, :worker_api_pr_lookup)

    Application.put_env(:symphony_elixir, :worker_api_pr_lookup, fn ^workspace_path, ^branch ->
      raise "gh unavailable"
    end)

    on_exit(fn ->
      if previous_lookup do
        Application.put_env(:symphony_elixir, :worker_api_pr_lookup, previous_lookup)
      else
        Application.delete_env(:symphony_elixir, :worker_api_pr_lookup)
      end

      File.rm_rf!(workspace_path)
    end)

    snapshot = worker_api_snapshot(%{branch_name: nil, workspace_path: workspace_path})
    orchestrator_name = Module.concat(__MODULE__, :WorkerFailedPrLookupOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    status_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/status"), 200)

    assert status_payload["workspace"]["branch"] == branch
    assert status_payload["pull_request"] == nil
    assert status_payload["checks"] == nil
  end

  test "agent worker status normalizes successful GitHub status contexts" do
    snapshot =
      worker_api_snapshot(%{
        branch_name: "codex/alb-66-status-contexts",
        pull_request: %{
          "number" => 115,
          "url" => "https://github.com/albert-zen/symphony-windows-native/pull/115",
          "statusCheckRollup" => [
            %{"context" => "legacy-success", "state" => "SUCCESS", "targetUrl" => "https://example.org/success"},
            %{"context" => "legacy-neutral", "state" => "NEUTRAL"},
            %{"context" => "legacy-skipped", "state" => "SKIPPED"}
          ]
        }
      })

    orchestrator_name = Module.concat(__MODULE__, :WorkerStatusContextProjectionOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    status_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/status"), 200)

    assert status_payload["checks"] == %{
             "summary" => "passing",
             "items" => [
               %{
                 "name" => "legacy-success",
                 "status" => "COMPLETED",
                 "conclusion" => "SUCCESS",
                 "details_url" => "https://example.org/success"
               },
               %{"name" => "legacy-neutral", "status" => "COMPLETED", "conclusion" => "NEUTRAL", "details_url" => nil},
               %{"name" => "legacy-skipped", "status" => "COMPLETED", "conclusion" => "SKIPPED", "details_url" => nil}
             ]
           }
  end

  test "agent worker status projects explicit PR URL while leaving checks unavailable" do
    snapshot =
      worker_api_snapshot(%{
        branch_name: "codex/alb-66-worker-observability",
        pull_request_url: "https://github.com/albert-zen/symphony-windows-native/pull/115"
      })

    orchestrator_name = Module.concat(__MODULE__, :WorkerPrUrlProjectionOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    status_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/status"), 200)

    assert status_payload["pull_request"] == %{
             "url" => "https://github.com/albert-zen/symphony-windows-native/pull/115"
           }

    assert status_payload["checks"] == nil
  end

  test "agent worker conversation API does not perform PR discovery" do
    workspace_root = Config.settings!().workspace.root
    workspace_path = Path.join(workspace_root, "MT-API-CONV-#{System.unique_integer([:positive])}")
    branch = "codex/alb-66-conversation"
    test_pid = self()

    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)
    {_, 0} = System.cmd("git", ["init"], cd: workspace_path, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["checkout", "-b", branch], cd: workspace_path, stderr_to_stdout: true)

    previous_lookup = Application.get_env(:symphony_elixir, :worker_api_pr_lookup)

    Application.put_env(:symphony_elixir, :worker_api_pr_lookup, fn _, _ ->
      send(test_pid, :unexpected_worker_pr_lookup)
      {:ok, %{url: "https://example.org/unexpected"}}
    end)

    on_exit(fn ->
      if previous_lookup do
        Application.put_env(:symphony_elixir, :worker_api_pr_lookup, previous_lookup)
      else
        Application.delete_env(:symphony_elixir, :worker_api_pr_lookup)
      end

      File.rm_rf!(workspace_path)
    end)

    snapshot =
      worker_api_snapshot(%{
        branch_name: nil,
        workspace_path: workspace_path,
        completed_agent_messages: [
          agent_completed_event("msg-processed", "Processed manager update.", ~U[2026-01-01 00:00:10Z])
        ]
      })

    orchestrator_name = Module.concat(__MODULE__, :WorkerConversationNoLookupOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/conversation"), 200)

    assert [%{"excerpt" => "Processed manager update."}] = payload["items"]
    refute_receive :unexpected_worker_pr_lookup
  end

  test "agent worker conversation API exposes processed agent messages without noisy timeline items" do
    snapshot =
      worker_api_snapshot(%{
        completed_agent_messages: [
          agent_completed_event("msg-processed", "Processed manager update.", ~U[2026-01-01 00:00:10Z])
        ],
        recent_codex_events: [
          notification_event("item/agentMessage/delta", %{"textDelta" => "streaming noise"}, 1),
          %{event: :unexpected_worker_event, message: "icon path warning", raw: %{}, timestamp: ~U[2026-01-01 00:00:02Z]}
        ]
      })

    orchestrator_name = Module.concat(__MODULE__, :WorkerConversationApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/conversation"), 200)

    assert payload == %{
             "issue_identifier" => "MT-API",
             "status" => "running",
             "source" => "conversation",
             "session" => %{
               "session_id" => "session-api",
               "thread_id" => "thread-api",
               "turn_count" => 3,
               "turn_id" => "turn-api"
             },
             "items" => [
               %{
                 "type" => "assistant",
                 "key" => "msg-processed",
                 "at" => "2026-01-01T00:00:10Z",
                 "title" => "Agent",
                 "excerpt" => "Processed manager update.",
                 "truncated?" => false
               }
             ]
           }

    rendered = inspect(payload, limit: :infinity)
    refute rendered =~ "streaming noise"
    refute rendered =~ "icon path warning"
  end

  test "agent worker debug events bound nested payload rendering before truncation" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerDebugBoundedOrchestrator)

    huge_payload =
      1..10
      |> Map.new(fn index ->
        {"key-#{index}", %{"nested" => List.duplicate("OPENAI_API_KEY=sk-live-secret", 100)}}
      end)
      |> Map.merge(%{
        "numeric" => 42,
        "flag" => true,
        "deep" => %{"a" => %{"b" => %{"c" => %{"d" => %{"e" => "bottom"}}}}}
      })

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot:
          worker_api_snapshot(%{
            recent_codex_events: [
              %{
                event: :notification,
                message: huge_payload,
                raw: huge_payload,
                payload: huge_payload,
                session_id: "session-api",
                thread_id: "thread-api",
                turn_id: "turn-api",
                timestamp: ~U[2026-01-01 00:00:01Z]
              }
            ]
          })
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    %{"events" => [%{"message" => message, "raw" => raw, "payload" => payload}]} =
      json_response(get(build_conn(), "/api/v1/workers/MT-API/debug/events?limit=1"), 200)

    assert message["truncated"] in [true, false]
    assert byte_size(message["text"]) <= message["limit_bytes"]
    assert byte_size(raw["text"]) <= raw["limit_bytes"]
    assert byte_size(payload["text"]) <= payload["limit_bytes"]
    refute inspect([message, raw, payload]) =~ "sk-live-secret"
  end

  test "agent worker APIs expose retry-only workers and stable missing worker errors" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerRetryOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: retry_worker_api_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    retry_status = json_response(get(build_conn(), "/api/v1/workers/MT-RETRY-API/status"), 200)

    assert retry_status["status"] == "retrying"
    assert retry_status["retry"]["attempt"] == 2
    assert retry_status["workspace"]["branch"] == "codex/alb-42-worker-apis"

    retry_timeline = json_response(get(build_conn(), "/api/v1/workers/MT-RETRY-API/timeline?limit=bad"), 200)
    assert retry_timeline == %{"issue_identifier" => "MT-RETRY-API", "items" => [], "limit" => 100, "next_before" => nil, "status" => "retrying"}

    assert json_response(get(build_conn(), "/api/v1/workers/MT-NOPE/status"), 404)["error"]["code"] ==
             "worker_not_found"
  end

  test "agent worker APIs handle unavailable snapshots as missing workers" do
    unavailable_orchestrator = Module.concat(__MODULE__, :WorkerUnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(get(build_conn(), "/api/v1/workers/MT-API/status"), 404)["error"]["code"] ==
             "worker_not_found"
  end

  test "agent worker timeline classifies supported event families" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerTimelineTypesOrchestrator)

    snapshot =
      worker_api_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], timeline_type_events())

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/timeline?limit=20"), 200)

    assert Enum.map(payload["items"], & &1["type"]) == [
             "system_warning",
             "state_change",
             "error",
             "state_change",
             "tool_call",
             "tool_call",
             "error",
             "assistant_message",
             "manager_steer"
           ]

    assert Enum.at(payload["items"], 7)["body"] =~ "agent message streaming"
    assert Enum.at(payload["items"], 4)["metadata"]["command"] == "git status"
  end

  test "agent worker timeline covers defensive event projections" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerTimelineDefensiveTypesOrchestrator)

    snapshot =
      worker_api_snapshot(%{
        command_watchdog: %{
          command: "mix test",
          status: :running,
          last_progress_at: ~U[2026-01-01 00:00:10Z]
        }
      })
      |> put_in([:running, Access.at(0), :recent_codex_events], defensive_timeline_events())
      |> Map.put(:retrying, [
        %{
          issue_id: "issue-api",
          identifier: "MT-API",
          title: "Worker API issue",
          url: "https://example.org/issues/MT-API",
          state: "In Progress",
          attempt: 1
        }
      ])

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    status_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/status"), 200)
    assert status_payload["status"] == "running"
    assert status_payload["command_watchdog"]["last_progress_at"] == "2026-01-01T00:00:10Z"

    timeline_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/timeline?before=bad"), 200)
    assert timeline_payload["items"] == []

    debug_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/debug/events?limit=20"), 200)
    assert Enum.any?(debug_payload["events"], &(&1["event"] == "string_event"))

    all_timeline_payload = json_response(get(build_conn(), "/api/v1/workers/MT-API/timeline?limit=20"), 200)
    bodies = Enum.map(all_timeline_payload["items"], & &1["body"])
    assert Enum.any?(bodies, &(&1 =~ "agent message streaming"))
    assert Enum.any?(bodies, &(&1 =~ "manager"))
    assert Enum.any?(bodies, &(&1 =~ "atom output"))
  end

  test "agent worker timeline truncates long streaming bodies" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerTimelineTruncateOrchestrator)
    long_text = String.duplicate("x", 4_050)

    snapshot =
      worker_api_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        notification_event("item/agentMessage/delta", %{"textDelta" => long_text}, 1)
      ])

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    %{"items" => [%{"body" => body, "truncated" => true}]} =
      json_response(get(build_conn(), "/api/v1/workers/MT-API/timeline"), 200)

    assert byte_size(body) == 4_000
  end

  test "agent worker timeline redacts secrets split across streaming deltas" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerTimelineSplitSecretOrchestrator)

    snapshot =
      worker_api_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        notification_event("item/agentMessage/delta", %{"textDelta" => "token sk-"}, 1),
        notification_event("item/agentMessage/delta", %{"textDelta" => "liveSecret123"}, 2)
      ])

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    %{"items" => [%{"body" => body}]} = json_response(get(build_conn(), "/api/v1/workers/MT-API/timeline"), 200)

    assert body == "token [REDACTED]"
    refute body =~ "sk-liveSecret123"
  end

  test "agent worker diff API returns stat, truncated patch, no diff, and workspace errors" do
    workspace_root = Config.settings!().workspace.root
    File.mkdir_p!(workspace_root)
    workspace_path = Path.join(workspace_root, "MT-DIFF-#{System.unique_integer([:positive])}")
    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)

    git!(workspace_path, ["init"])
    git!(workspace_path, ["config", "user.email", "codex@example.test"])
    git!(workspace_path, ["config", "user.name", "Codex"])
    File.write!(Path.join(workspace_path, "notes.txt"), "first\n")
    git!(workspace_path, ["add", "notes.txt"])
    git!(workspace_path, ["commit", "-m", "initial"])
    File.write!(Path.join(workspace_path, "notes.txt"), "first\nOPENAI_API_KEY=sk-live-secret\n")

    orchestrator_name = Module.concat(__MODULE__, :WorkerDiffOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: worker_api_snapshot(%{identifier: "MT-DIFF", workspace_path: workspace_path})
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    stat_payload = json_response(get(build_conn(), "/api/v1/workers/MT-DIFF/diff"), 200)

    assert stat_payload["changed_files"] == ["notes.txt"]
    assert stat_payload["format"] == "stat"
    assert stat_payload["empty"] == false
    assert stat_payload["patch"] == nil

    patch_payload =
      json_response(get(build_conn(), "/api/v1/workers/MT-DIFF/diff?format=patch&limit_bytes=20"), 200)

    assert patch_payload["patch"]["truncated"] == true
    refute patch_payload["patch"]["text"] =~ "sk-live-secret"

    git!(workspace_path, ["checkout", "--", "notes.txt"])

    assert %{"empty" => true, "changed_files" => []} =
             json_response(get(build_conn(), "/api/v1/workers/MT-DIFF/diff"), 200)

    File.write!(Path.join(workspace_path, "new_notes.txt"), "OPENAI_API_KEY=sk-live-secret\n")

    untracked_stat_payload = json_response(get(build_conn(), "/api/v1/workers/MT-DIFF/diff"), 200)
    assert "new_notes.txt" in untracked_stat_payload["changed_files"]
    assert untracked_stat_payload["stat"]["text"] =~ "new_notes.txt"

    untracked_patch_payload =
      json_response(get(build_conn(), "/api/v1/workers/MT-DIFF/diff?format=patch&limit_bytes=400"), 200)

    assert untracked_patch_payload["patch"]["text"] =~ "new file mode"
    assert untracked_patch_payload["patch"]["text"] =~ "new_notes.txt"
    refute untracked_patch_payload["patch"]["text"] =~ "sk-live-secret"
  end

  test "agent worker diff API bounds and classifies untracked non-regular entries" do
    workspace_root = Config.settings!().workspace.root
    File.mkdir_p!(workspace_root)
    workspace_path = Path.join(workspace_root, "MT-DIFF-EDGE-#{System.unique_integer([:positive])}")
    outside_path = Path.join(workspace_root, "outside-secret-#{System.unique_integer([:positive])}.txt")
    File.rm_rf!(workspace_path)
    File.mkdir_p!(workspace_path)

    git!(workspace_path, ["init"])
    git!(workspace_path, ["config", "user.email", "codex@example.test"])
    git!(workspace_path, ["config", "user.name", "Codex"])
    File.write!(Path.join(workspace_path, "tracked.txt"), "first\n")
    git!(workspace_path, ["add", "tracked.txt"])
    git!(workspace_path, ["commit", "-m", "initial"])

    File.mkdir_p!(Path.join(workspace_path, "adir"))
    File.write!(Path.join([workspace_path, "adir", "nested.txt"]), "nested\n")
    File.write!(Path.join(workspace_path, "large.bin"), :binary.copy(<<0, 255, 1, 2>>, 20_000))
    File.write!(outside_path, "OPENAI_API_KEY=sk-live-secret\n")

    if is_nil(SymphonyElixir.TestSupport.symlink_skip_reason()) do
      :ok = File.ln_s(outside_path, Path.join(workspace_path, "outside-link.txt"))
    end

    orchestrator_name = Module.concat(__MODULE__, :WorkerDiffEdgeOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: worker_api_snapshot(%{identifier: "MT-DIFF-EDGE", workspace_path: workspace_path})
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    stat_payload = json_response(get(build_conn(), "/api/v1/workers/MT-DIFF-EDGE/diff"), 200)
    assert "adir/" in stat_payload["changed_files"]
    assert "large.bin" in stat_payload["changed_files"]
    assert stat_payload["stat"]["text"] =~ "adir/"
    assert stat_payload["stat"]["text"] =~ "directory"

    patch_payload =
      json_response(get(build_conn(), "/api/v1/workers/MT-DIFF-EDGE/diff?format=patch&limit_bytes=600"), 200)

    assert byte_size(patch_payload["patch"]["text"]) <= patch_payload["patch"]["limit_bytes"]
    assert patch_payload["patch"]["text"] =~ "adir/"
    assert patch_payload["patch"]["text"] =~ "large.bin"
    refute patch_payload["patch"]["text"] =~ "sk-live-secret"
  end

  test "agent worker diff API has stable missing workspace semantics" do
    workspace_root = Config.settings!().workspace.root
    missing_snapshot = worker_api_snapshot(%{identifier: "MT-MISSING-WS", workspace_path: Path.join(workspace_root, "missing")})
    orchestrator_name = Module.concat(__MODULE__, :WorkerDiffMissingOrchestrator)

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: missing_snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(get(build_conn(), "/api/v1/workers/MT-MISSING-WS/diff"), 404)["error"]["code"] ==
             "workspace_missing"
  end

  test "agent worker diff API has stable non-git workspace semantics" do
    workspace_root = Config.settings!().workspace.root
    workspace_path = Path.join(workspace_root, "MT-NOGIT-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace_path)

    orchestrator_name = Module.concat(__MODULE__, :WorkerDiffNoGitOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: worker_api_snapshot(%{identifier: "MT-NOGIT", workspace_path: workspace_path})
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(get(build_conn(), "/api/v1/workers/MT-NOGIT/diff"), 409)["error"]["code"] ==
             "not_git_repo"
  end

  test "agent worker diff API rejects workspaces outside the configured root" do
    outside_path = Path.join(System.tmp_dir!(), "symphony-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside_path)

    orchestrator_name = Module.concat(__MODULE__, :WorkerDiffUnsafeOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: worker_api_snapshot(%{identifier: "MT-UNSAFE", workspace_path: outside_path})
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(get(build_conn(), "/api/v1/workers/MT-UNSAFE/diff"), 403) == %{
             "error" => %{
               "code" => "workspace_outside_root",
               "message" => "Worker workspace is outside the configured workspace root"
             }
           }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ ~r"/dashboard\.css\?v=[A-Za-z0-9_-]+"
    assert html =~ ~r"/vendor/phoenix_html/phoenix_html\.js\?v=[A-Za-z0-9_-]+"
    assert html =~ ~r"/vendor/phoenix/phoenix\.js\?v=[A-Za-z0-9_-]+"
    assert html =~ ~r"/vendor/phoenix_live_view/phoenix_live_view\.js\?v=[A-Za-z0-9_-]+"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    versioned_dashboard_css = response(get(build_conn(), "/dashboard.css?v=cache-busted"), 200)
    assert versioned_dashboard_css == dashboard_css

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ ~s|class="page-brand">Symphony|
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Capacity"
    assert html =~ "page-live"
    assert html =~ "Snapshot current"
    assert html =~ ~s(href="/config")
    assert html =~ "Config"
    assert html =~ ~s(id="system-debug")
    assert html =~ ~s(phx-hook="PreserveDetails")
    refute html =~ "Operations Dashboard"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview does not double-count active runtime totals" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardRuntimeOrchestrator)

    snapshot =
      static_snapshot()
      |> put_in([:codex_totals, :seconds_running], 120)
      |> put_in([:running, Access.at(0), :started_at], DateTime.add(DateTime.utc_now(), -120, :second))

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "2m "
    refute html =~ "4m "
  end

  test "dashboard liveview requests log unicode timings through the file formatter" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardFormatterOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    log =
      with_file_log_handler(fn ->
        :logger.log(:debug, {"Replied in ~B~ts", [409, ~c"µs"]}, %{request_path: "/"})
        {:ok, _index_view, index_html} = live(build_conn(), "/")

        :logger.log(:debug, {"Replied in ~B~ts", [512, ~c"µs"]}, %{
          request_path: "/workers/MT-HTTP"
        })

        {:ok, _detail_view, detail_html} = live(build_conn(), "/workers/MT-HTTP")

        assert index_html =~ ~s|class="page-brand">Symphony|
        assert detail_html =~ ~s|class="page-brand-id">MT-HTTP|
      end)

    assert log =~ "Replied in 409µs"
    assert log =~ "Replied in 512µs"
    assert String.valid?(log)
    refute log =~ "FORMATTER ERROR"
  end

  test "dashboard liveview renders populated rate limits as readable status" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardRateLimitOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:rate_limits, %{
        "limitId" => "codex",
        "planType" => "prolite",
        "primary" => %{
          "usedPercent" => 57,
          "windowDurationMins" => 300,
          "resetAt" => "2099-05-02T07:05:00Z"
        },
        "secondary" => %{
          "usedPercent" => 92,
          "windowDurationMins" => 10_080,
          "resetInSeconds" => 250
        }
      })

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    # The redesigned dashboard surfaces only the primary used-percent label in
    # the sidebar Capacity card. The rest of the rate-limit detail moves into
    # the System debug drawer (raw map). We assert the operator-facing summary
    # plus the raw payload presence; per-bucket detail is exercised at the
    # API level separately.
    assert html =~ "57% used · primary rate limit"
    assert html =~ "Capacity"
    assert html =~ "System debug"
  end

  test "dashboard liveview renders partial rate limits without raw map as the main view" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardPartialRateLimitOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:rate_limits, %{
        limit_name: "codex-lite",
        primary: %{usedPercent: 40, windowDurationMins: nil},
        secondary: %{usedPercent: nil, resetsAt: 4_081_392_600}
      })

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "40% used · primary rate limit"
    assert html =~ "Capacity"
  end

  test "dashboard liveview renders absent rate limits as an empty state" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardAbsentRateLimitOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:rate_limits, nil)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    # Without a rate-limit snapshot, the Capacity bar reports "n/a used".
    assert html =~ "n/a · primary rate limit"
    assert html =~ "Capacity"
  end

  test "worker detail liveview renders chat panel and submits session-scoped steer messages" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        parent: self(),
        snapshot: static_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/workers/MT-HTTP")
    # New rollout-backed shell: identifier, sidebar/status block, and the steer composer.
    assert html =~ ~s|class="page-brand-id">MT-HTTP|
    assert html =~ "thread-http"
    assert html =~ "Transcript"
    assert html =~ "Steer the agent"
    refute html =~ "Keep the PR focused."
    refute html =~ "Debug JSON"
    refute html =~ "Raw worker payload"

    render_submit(view, "steer", %{
      "steer" => %{
        "message" => "Use the narrower UI fix.",
        "session_id" => "thread-http"
      }
    })

    assert_received {:steer_worker_called, "MT-HTTP", "Use the narrower UI fix.", "thread-http"}
  end

  test "worker detail transcript disclosures preserve open state across patches" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailDisclosureOrchestrator)
    workspace_root = Config.settings!().workspace.root
    workspace_path = Path.join(workspace_root, "MT-HTTP")

    sessions_root =
      System.tmp_dir!()
      |> Path.join("symphony-rollouts-#{System.unique_integer([:positive])}")
      |> Path.expand()

    write_transcript_disclosure_rollout!(sessions_root, workspace_path)
    rollout_index_state = :sys.get_state(RolloutIndex)

    on_exit(fn ->
      :sys.replace_state(RolloutIndex, fn _ -> rollout_index_state end)
      File.rm_rf(sessions_root)
    end)

    File.mkdir_p!(workspace_path)

    :sys.replace_state(RolloutIndex, fn state ->
      %{state | sessions_root: sessions_root, workspace_root: Path.expand(workspace_root)}
    end)

    RolloutIndex.refresh()
    assert [_rollout] = RolloutIndex.lookup("MT-HTTP")

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/workers/MT-HTTP")

    assert html =~ "tool_call"
    assert html =~ "thinking deeply"
    assert html =~ ~s(class="transcript-details")
    assert html =~ ~s(phx-hook="PreserveDetails")
  end

  test "worker detail projection renders completed agent messages and hides command output" do
    hidden_marker = "TAIL_SHOULD_NOT_RENDER"
    long_output = String.duplicate("a", 2_050) <> hidden_marker <> String.duplicate("b", 600)

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        agent_delta_event("msg-1", "Hello ", ~U[2026-01-01 00:00:00Z]),
        agent_completed_event("msg-1", "Hello manager.", ~U[2026-01-01 00:00:01Z]),
        command_event("item/started", %{"item" => %{"id" => "cmd-1", "type" => "commandExecution", "command" => "mix test"}}, ~U[2026-01-01 00:00:02Z]),
        command_event("item/commandExecution/outputDelta", %{"itemId" => "cmd-1", "outputDelta" => long_output}, ~U[2026-01-01 00:00:03Z]),
        command_event("item/completed", %{"item" => %{"id" => "cmd-1", "type" => "commandExecution", "exitCode" => 0}}, ~U[2026-01-01 00:00:04Z])
      ])

    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailConversationOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    assert [%{"type" => "assistant", "excerpt" => "Hello manager."}] = issue_payload["conversation"]
    refute Map.has_key?(List.first(issue_payload["conversation"]), "content")

    rendered_payload = inspect(issue_payload, limit: :infinity)
    refute rendered_payload =~ hidden_marker

    # The LiveView no longer renders orchestrator-buffered conversation —
    # transcript is sourced from the on-disk Codex JSONL via RolloutReader.
    # We still verify the API projection above; the LiveView shell renders
    # the worker identifier and the empty-rollouts state in this fixture.
    {:ok, _view, html} = live(build_conn(), "/workers/MT-HTTP")
    assert html =~ ~s|class="page-brand-id">MT-HTTP|
    refute html =~ hidden_marker
  end

  test "worker detail projection uses durable completed messages when raw events roll over" do
    noisy_recent_events =
      1..80
      |> Enum.map(fn index ->
        command_event("item/commandExecution/outputDelta", %{"itemId" => "cmd-#{index}", "outputDelta" => "noise #{index}"}, DateTime.add(~U[2026-01-01 00:00:00Z], index, :second))
      end)

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], noisy_recent_events)
      |> put_in([:running, Access.at(0), :completed_agent_messages], [
        agent_completed_event("msg-durable", "Durable message survives noise.", ~U[2026-01-01 00:00:00Z])
      ])

    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailDurableMessagesOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    assert [%{"type" => "assistant", "excerpt" => "Durable message survives noise."}] = issue_payload["conversation"]

    # LiveView transcript is sourced from on-disk Codex JSONL, not the
    # orchestrator's in-memory completed_agent_messages — verified at the
    # API layer above. The shell still renders for an active worker.
    {:ok, _view, html} = live(build_conn(), "/workers/MT-HTTP")
    assert html =~ ~s|class="page-brand-id">MT-HTTP|
    refute html =~ "noise 80"
  end

  test "worker detail projection redacts secrets from completed agent messages" do
    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        agent_delta_event("msg-secret", "token sk-", ~U[2026-01-01 00:00:00Z]),
        agent_completed_event("msg-secret", "token sk-liveSecret123", ~U[2026-01-01 00:00:01Z]),
        command_event(
          "item/started",
          %{"item" => %{"id" => "cmd-secret", "type" => "commandExecution", "command" => "mix test"}},
          ~U[2026-01-01 00:00:02Z]
        ),
        command_event("item/commandExecution/outputDelta", %{"itemId" => "cmd-secret", "outputDelta" => "Authorization: Bearer sk-"}, ~U[2026-01-01 00:00:03Z]),
        command_event("item/commandExecution/outputDelta", %{"itemId" => "cmd-secret", "outputDelta" => "liveSecret123"}, ~U[2026-01-01 00:00:04Z])
      ])

    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailCoalescedSecretOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    rendered_payload = inspect(issue_payload, limit: :infinity)

    assert [%{"type" => "assistant", "excerpt" => "token [REDACTED]"}] =
             issue_payload["conversation"]

    refute rendered_payload =~ "sk-liveSecret123"
  end

  test "worker detail projection ignores streaming textDelta assistant chunks" do
    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        notification_event("item/agentMessage/delta", %{"textDelta" => "Hello "}, 1),
        notification_event("item/agentMessage/delta", %{"textDelta" => "from textDelta"}, 2)
      ])

    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailTextDeltaOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)

    assert issue_payload["conversation"] == []
  end

  test "worker detail projection reads completed messages when raw app-server JSON is a string" do
    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        raw_json_event("item/agentMessage/delta", %{"itemId" => "msg-json", "delta" => "Production "}, ~U[2026-01-01 00:00:00Z]),
        raw_json_event("item/completed", %{"item" => %{"id" => "msg-json", "type" => "agentMessage", "text" => "Production delta"}}, ~U[2026-01-01 00:00:01Z]),
        raw_json_event(
          "item/started",
          %{"item" => %{"id" => "cmd-json", "type" => "commandExecution", "command" => ["mix", "test"]}},
          ~U[2026-01-01 00:00:02Z]
        ),
        raw_json_event("item/commandExecution/outputDelta", %{"itemId" => "cmd-json", "outputDelta" => "ok\n"}, ~U[2026-01-01 00:00:03Z]),
        raw_json_event(
          "item/completed",
          %{"item" => %{"id" => "cmd-json", "type" => "commandExecution", "exitCode" => 0}},
          ~U[2026-01-01 00:00:04Z]
        )
      ])

    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailRawJsonConversationOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    assert [%{"type" => "assistant", "excerpt" => "Production delta"}] = issue_payload["conversation"]
  end

  test "worker detail projection handles completed content lists and hides parsed command fields" do
    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        raw_json_event(
          "item/completed",
          %{"item" => %{"id" => "msg-content", "type" => "agentMessage", "content" => [%{"text" => "Content delta"}]}},
          ~U[2026-01-01 00:00:00Z]
        ),
        raw_json_event(
          "item/started",
          %{"item" => %{"id" => "cmd-parsed", "type" => "commandExecution", "parsedCmd" => "mix specs.check"}},
          ~U[2026-01-01 00:00:01Z]
        )
      ])

    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailContentDeltaOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)

    assert [%{"type" => "assistant", "excerpt" => "Content delta"}] =
             issue_payload["conversation"]
  end

  test "worker detail projection caps many display items" do
    many_events =
      1..160
      |> Enum.map(fn index ->
        agent_completed_event("msg-#{index}", "agent event #{index}", DateTime.add(~U[2026-01-01 00:00:00Z], index, :second))
      end)

    snapshot = put_in(static_snapshot(), [:running, Access.at(0), :recent_codex_events], many_events)
    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailManyEventsOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    assert length(issue_payload["conversation"]) == 120
    assert length(issue_payload["timeline"]) == 120
    refute Enum.any?(issue_payload["conversation"], &(&1["excerpt"] == "agent event 1"))
    assert List.last(issue_payload["conversation"])["excerpt"] == "agent event 160"
  end

  test "worker detail projection does not process oversized raw payloads outside the display window" do
    hidden_old_marker = "OLD_RAW_MARKER_SHOULD_NOT_LEAK"

    old_oversized_event = %{
      event: :notification,
      message: "old oversized event",
      raw: %{
        "html_blob" => String.duplicate("<html>cloudflare</html>", 500) <> hidden_old_marker,
        "items" => Enum.map(1..200, &%{"index" => &1, "value" => String.duplicate("x", 100)})
      },
      session_id: "thread-http",
      thread_id: "thread-http",
      turn_id: "turn-http",
      timestamp: ~U[2026-01-01 00:00:00Z]
    }

    recent_events =
      1..420
      |> Enum.map(fn index ->
        agent_completed_event("msg-recent-#{index}", "recent agent event #{index}", DateTime.add(~U[2026-01-01 00:00:00Z], index, :second))
      end)

    snapshot = put_in(static_snapshot(), [:running, Access.at(0), :recent_codex_events], [old_oversized_event | recent_events])
    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailOversizedOldEventsOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    rendered_payload = inspect(issue_payload, limit: :infinity)

    assert length(issue_payload["conversation"]) == 120
    refute rendered_payload =~ hidden_old_marker
    refute rendered_payload =~ "old oversized event"
  end

  test "worker detail projection keeps large assistant and debug payloads bounded" do
    hidden_assistant_marker = "ASSISTANT_TAIL_SHOULD_NOT_LEAK"
    hidden_debug_marker = "DEBUG_TAIL_SHOULD_NOT_LEAK"

    long_delta = String.duplicate("c", 2_050) <> hidden_assistant_marker
    long_debug_value = String.duplicate("d", 1_650) <> hidden_debug_marker

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :giant_debug_blob], long_debug_value)
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        agent_completed_event("msg-long", long_delta, ~U[2026-01-01 00:00:00Z])
      ])

    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailBoundedPayloadOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    rendered_payload = inspect(issue_payload, limit: :infinity)

    assert [%{"type" => "assistant"} = assistant] = issue_payload["conversation"]
    assert assistant["truncated?"] == true
    assert String.length(String.replace_suffix(assistant["excerpt"], "\n[truncated]", "")) == 2_000
    refute Map.has_key?(assistant, "content")
    assert issue_payload["debug"]["payload_truncated?"] == true
    refute rendered_payload =~ hidden_assistant_marker
    refute rendered_payload =~ hidden_debug_marker

    {:ok, _view, html} = live(build_conn(), "/workers/MT-HTTP")
    refute html =~ hidden_assistant_marker
    refute html =~ hidden_debug_marker
  end

  test "worker detail completed messages preserve redaction and hide raw debug fields" do
    secret = "OPENAI_API_KEY=sk-live-secret"

    many_small_fields =
      1..60
      |> Map.new(fn index -> {"field_#{index}", "value_#{index}"} end)
      |> Map.put("secret", secret)

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        agent_completed_event("msg-many", "Done with #{secret}", ~U[2026-01-01 00:00:00Z]),
        command_event("item/started", %{"item" => Map.merge(many_small_fields, %{"id" => "cmd-many", "type" => "commandExecution", "command" => "mix test"})}, ~U[2026-01-01 00:00:01Z])
      ])

    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailDebugTruncationOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    rendered_payload = inspect(issue_payload, limit: :infinity)

    assert [%{"type" => "assistant", "excerpt" => "Done with OPENAI_API_KEY=[REDACTED]"}] = issue_payload["conversation"]
    refute rendered_payload =~ "sk-live-secret"
    assert rendered_payload =~ "[REDACTED]"
  end

  test "worker detail debug excerpts bound large decoded lists and large raw JSON strings" do
    hidden_list_marker = "LIST_TAIL_SHOULD_NOT_LEAK"
    hidden_json_marker = "JSON_TAIL_SHOULD_NOT_LEAK"

    large_list =
      Enum.map(1..80, fn index ->
        %{"index" => index, "value" => if(index == 80, do: hidden_list_marker, else: "value")}
      end)

    large_json =
      Jason.encode!(%{
        method: "item/agentMessage/delta",
        params: %{
          itemId: "large-json",
          delta: String.duplicate("j", 20_000) <> hidden_json_marker,
          token: "sk-large-json-secret"
        }
      })

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        command_event(
          "item/started",
          %{"item" => %{"id" => "cmd-list", "type" => "commandExecution", "command" => "mix test", "details" => large_list}},
          ~U[2026-01-01 00:00:00Z]
        ),
        %{
          event: :codex_event,
          message: nil,
          raw: large_json,
          session_id: "thread-http",
          thread_id: "thread-http",
          turn_id: "turn-http",
          timestamp: ~U[2026-01-01 00:00:01Z]
        }
      ])

    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailLargeDebugBoundsOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    rendered_payload = inspect(issue_payload, limit: :infinity)

    assert issue_payload["conversation"] == []
    refute rendered_payload =~ hidden_list_marker
    refute rendered_payload =~ hidden_json_marker
    refute rendered_payload =~ "sk-large-json-secret"
  end

  test "worker detail bounded excerpts redact secrets crossing truncation boundary" do
    secret_prefix = "sk-" <> String.duplicate("a", 1_700)

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        %{
          event: :notification,
          message: nil,
          raw: ~s({"password":"#{secret_prefix}),
          session_id: "thread-http",
          thread_id: "thread-http",
          turn_id: "turn-http",
          timestamp: ~U[2026-01-01 00:00:00Z]
        },
        %{
          event: :notification,
          message: nil,
          raw: "OPENAI_API_KEY=#{secret_prefix}",
          session_id: "thread-http",
          thread_id: "thread-http",
          turn_id: "turn-http",
          timestamp: ~U[2026-01-01 00:00:01Z]
        }
      ])

    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailBoundaryRedactionOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    rendered_payload = inspect(issue_payload, limit: :infinity)

    refute rendered_payload =~ "sk-"
    refute rendered_payload =~ String.slice(secret_prefix, 0, 100)
    assert rendered_payload =~ "[REDACTED]"
  end

  test "worker detail redacts visible fields derived from raw-only map events" do
    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        %{
          event: :codex_event,
          message: nil,
          raw: %{
            "method" => "item/started",
            "params" => %{
              "item" => %{
                "id" => "cmd-secret",
                "type" => "commandExecution",
                "command" => "curl https://example.test?token=raw-visible-secret"
              }
            }
          },
          session_id: "thread-http",
          thread_id: "thread-http",
          turn_id: "turn-http",
          timestamp: ~U[2026-01-01 00:00:00Z]
        },
        %{
          event: :codex_event,
          message: nil,
          raw: %{
            "method" => "item/commandExecution/outputDelta",
            "params" => %{
              "itemId" => "cmd-secret",
              "outputDelta" => "Authorization: Bearer raw-output-secret"
            }
          },
          session_id: "thread-http",
          thread_id: "thread-http",
          turn_id: "turn-http",
          timestamp: ~U[2026-01-01 00:00:01Z]
        }
      ])

    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailRawMapVisibleRedactionOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    rendered_payload = inspect(issue_payload, limit: :infinity)

    refute rendered_payload =~ "raw-visible-secret"
    refute rendered_payload =~ "raw-output-secret"
    assert rendered_payload =~ "[REDACTED]"
  end

  test "worker detail liveview rejects missing or blank steer session ids" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailSteerSessionGuardOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        parent: self(),
        snapshot: static_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/workers/MT-HTTP")

    render_submit(view, "steer", %{
      "steer" => %{
        "message" => "Do not send without a session."
      }
    })

    render_submit(view, "steer", %{
      "steer" => %{
        "message" => "Do not send with a blank session.",
        "session_id" => "   "
      }
    })

    refute_received {:steer_worker_called, "MT-HTTP", _message, _session_id}
  end

  test "worker detail projections redact secret-like raw event values" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailRedactionOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: secret_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    api_payload = json_response(get(build_conn(), "/api/v1/MT-SECRET"), 200)
    rendered_api = inspect(api_payload, limit: :infinity)

    refute rendered_api =~ "sk-live-secret"
    refute rendered_api =~ "p4ss"
    refute rendered_api =~ "live-token"
    refute rendered_api =~ "user:pass"
    refute rendered_api =~ "token=abc123"
    assert rendered_api =~ "[REDACTED]"

    {:ok, _view, html} = live(build_conn(), "/workers/MT-SECRET")

    # Negative assertions still matter — confirm none of the orchestrator
    # buffers leak into the new shell. The "[REDACTED]" marker only
    # appears in the API/Presenter projection, not the LiveView shell,
    # because the new transcript reads from on-disk Codex JSONL.
    refute html =~ "sk-live-secret"
    refute html =~ "p4ss"
    refute html =~ "live-token"
    refute html =~ "user:pass"
    refute html =~ "token=abc123"
  end

  test "worker detail liveview requires operator token when steer auth is enabled" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailSteerAuthOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        parent: self(),
        snapshot: static_snapshot()
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      steer_auth_required: true,
      steer_token: "letmein"
    )

    {:ok, view, html} = live(build_conn(), "/workers/MT-HTTP")
    assert html =~ "Operator token"

    render_submit(view, "steer", %{
      "steer" => %{
        "message" => "Do not send this.",
        "session_id" => "thread-http",
        "operator_token" => "wrong"
      }
    })

    refute_received {:steer_worker_called, "MT-HTTP", "Do not send this.", "thread-http"}

    render_submit(view, "steer", %{
      "steer" => %{
        "message" => "Use the authenticated steer path.",
        "session_id" => "thread-http",
        "operator_token" => "letmein"
      }
    })

    assert_received {:steer_worker_called, "MT-HTTP", "Use the authenticated steer path.", "thread-http"}
  end

  test "worker detail liveview locks steering when exposed without an operator token" do
    orchestrator_name = Module.concat(__MODULE__, :WorkerDetailSteerLockedOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        parent: self(),
        snapshot: static_snapshot()
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      steer_auth_required: true,
      steer_token: "   "
    )

    {:ok, view, html} = live(build_conn(), "/workers/MT-HTTP")
    assert html =~ "Steering is locked"

    render_submit(view, "steer", %{
      "steer" => %{
        "message" => "Do not send this.",
        "session_id" => "thread-http"
      }
    })

    refute_received {:steer_worker_called, "MT-HTTP", "Do not send this.", "thread-http"}
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "operator config liveview renders editable workflow with redacted parsed summary" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "sk-test-linear-secret")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$LINEAR_API_KEY",
      prompt: "Use the workflow. OPENAI_API_KEY=$OPENAI_API_KEY"
    )

    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :ConfigLiveOrchestrator),
      snapshot_timeout_ms: 50
    )

    {:ok, _view, html} = live(build_conn(), "/config")

    assert html =~ "Operator Config"
    assert html =~ "Workflow.md editor"
    assert html =~ Workflow.workflow_file_path()
    assert html =~ "Workflow file"
    assert html =~ "Workflow.md"
    assert html =~ "Apply behavior"
    assert html =~ "reloads WorkflowStore immediately"
    assert html =~ "Tracker"
    assert html =~ "API key"
    assert html =~ "configured"
    refute html =~ "sk-test-linear-secret"
    assert html =~ "Dispatch"
    assert html =~ "Todo"
    assert html =~ "Prompt body"
    assert html =~ "$LINEAR_API_KEY"
    assert html =~ "OPENAI_API_KEY=$OPENAI_API_KEY"
  end

  test "operator config liveview previews and applies safe workflow edits" do
    workflow_path = Workflow.workflow_file_path()

    write_workflow_file!(workflow_path,
      max_concurrent_agents: 3,
      poll_interval_ms: 5_000,
      observability_refresh_ms: 1_000
    )

    orchestrator_name = Module.concat(__MODULE__, :ConfigLiveEditOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: %{running: [], retrying: [], codex_totals: %{}, rate_limits: nil}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5)

    {:ok, view, _html} = live(build_conn(), "/config")
    current = File.read!(workflow_path)

    proposed =
      current
      |> String.replace("max_concurrent_agents: 3", "max_concurrent_agents: 4")
      |> String.replace("interval_ms: 5000", "interval_ms: 7500")
      |> String.replace("refresh_ms: 1000", "refresh_ms: 2500")

    html =
      view
      |> form("#workflow-config-editor",
        workflow: %{
          "content" => proposed
        }
      )
      |> render_submit()

    assert html =~ "Diff preview"
    assert html =~ "Application notes"
    assert html =~ "No runtime restart is expected"
    assert html =~ "+  max_concurrent_agents: 4"
    assert html =~ "+  interval_ms: 7500"
    assert html =~ "+  refresh_ms: 2500"

    _html = view |> element("button", "Apply") |> render_click()

    assert File.read!(workflow_path) =~ "max_concurrent_agents: 4"
    assert File.read!(workflow_path) =~ "interval_ms: 7500"
    assert File.read!(workflow_path) =~ "refresh_ms: 2500"
  end

  test "operator config liveview requires preview before applying workflow edits" do
    write_workflow_file!(Workflow.workflow_file_path())

    orchestrator_name = Module.concat(__MODULE__, :ConfigLiveNoPreviewOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: %{running: [], retrying: [], codex_totals: %{}, rate_limits: nil}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/config")

    assert html =~ ~s(disabled)
    assert html =~ "Apply"
  end

  test "operator config liveview rejects invalid full workflow content" do
    workflow_path = Workflow.workflow_file_path()
    write_workflow_file!(workflow_path)
    original = File.read!(workflow_path)

    orchestrator_name = Module.concat(__MODULE__, :ConfigLiveInvalidContentOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: %{running: [], retrying: [], codex_totals: %{}, rate_limits: nil}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5)

    {:ok, view, _html} = live(build_conn(), "/config")

    html =
      view
      |> form("#workflow-config-editor", workflow: %{"content" => "---\ntracker: [\n---\nprompt"})
      |> render_submit()

    assert html =~ "tracker: ["
    refute html =~ "Diff preview"
    assert File.read!(workflow_path) == original
  end

  test "operator config liveview blocks workflow apply while workers are active" do
    workflow_path = Workflow.workflow_file_path()
    write_workflow_file!(workflow_path, max_concurrent_agents: 2)

    orchestrator_name = Module.concat(__MODULE__, :ConfigLiveActiveWorkersOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5)

    {:ok, view, _html} = live(build_conn(), "/config")

    proposed =
      workflow_path
      |> File.read!()
      |> String.replace("max_concurrent_agents: 2", "max_concurrent_agents: 3")

    _html =
      view
      |> form("#workflow-config-editor", workflow: %{"content" => proposed})
      |> render_submit()

    html = view |> element("button", "Apply") |> render_click()

    assert html =~ "1 active workers"
    assert File.read!(workflow_path) =~ "max_concurrent_agents: 2"
  end

  test "workflow config projection reports redacted settings and prompt metadata" do
    long_prompt =
      "Use the workflow. OPENAI_API_KEY=sk-live-secret\n" <>
        String.duplicate("Keep config visible without leaking secrets. ", 12)

    previous_steer_token = System.get_env("SYMPHONY_STEER_TOKEN")
    System.put_env("SYMPHONY_STEER_TOKEN", "steer-secret")
    on_exit(fn -> restore_env("SYMPHONY_STEER_TOKEN", previous_steer_token) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "sk-live-secret",
      tracker_assignee: "operator@example.test",
      tracker_labels: ["Ops", "ops", "Support"],
      max_concurrent_agents_by_state: %{"Todo" => 5},
      worker_max_concurrent_agents_per_host: 3,
      codex_turn_sandbox_policy: %{"type" => "workspaceWrite", "token" => "sk-live-secret"},
      hook_after_create: "powershell setup.ps1",
      observability_refresh_ms: 5_000,
      prompt: long_prompt
    )

    projection = SymphonyElixirWeb.WorkflowConfigProjection.current()

    assert projection.status == :ok
    assert projection.workflow.exists? == true
    assert projection.workflow.hash =~ ~r/^[a-f0-9]{12}$/
    assert projection.config.tracker.api_key == "configured"
    assert projection.config.tracker.assignee == "configured"
    assert projection.config.tracker.labels == ["ops", "support"]
    assert projection.config.concurrency.per_host == 3
    assert projection.config.concurrency.by_state == %{"todo" => 5}
    assert projection.config.hooks.after_create == "configured"
    assert projection.config.observability.refresh_ms == 5_000
    assert projection.config.observability.steer_token == "configured"
    assert projection.config.codex.turn_sandbox_policy["token"] == "[REDACTED]"
    assert projection.prompt.lines == 2
    assert projection.prompt.preview =~ "OPENAI_API_KEY=[REDACTED]"
    assert String.ends_with?(projection.prompt.preview, "...")

    rendered = inspect(projection, limit: :infinity)
    refute rendered =~ "sk-live-secret"
    refute rendered =~ "steer-secret"
  end

  test "operator config liveview renders missing workflow errors" do
    workflow_store_pid = Process.whereis(WorkflowStore)
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_CONFIG_WORKFLOW.md")

    if is_pid(workflow_store_pid) do
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    end

    Workflow.set_workflow_file_path(missing_path)

    on_exit(fn ->
      Workflow.clear_workflow_file_path()

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(WorkflowStore)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
          {:error, :not_found} -> :ok
          {:error, _reason} -> :ok
        end
      end
    end)

    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :ConfigLiveMissingWorkflowOrchestrator),
      snapshot_timeout_ms: 50
    )

    {:ok, _view, html} = live(build_conn(), "/config")

    assert html =~ "Operator Config"
    assert html =~ "Workflow unavailable"
    assert html =~ "missing"
    assert html =~ missing_path
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp with_file_log_handler(fun) do
    path = Path.join(System.tmp_dir!(), "symphony-dashboard-log-#{System.unique_integer([:positive])}.log")
    handler_id = :"symphony_dashboard_log_test_#{System.unique_integer([:positive])}"
    primary_level = :logger.get_primary_config() |> Map.fetch!(:level)

    :ok =
      :logger.add_handler(handler_id, :logger_std_h, %{
        level: :debug,
        formatter:
          {Formatter,
           %{
             single_line: true,
             template: [:time, " ", :level, " event_id=", :event_id, " ", :msg, "\n"]
           }},
        config: %{type: {:file, String.to_charlist(path)}}
      })

    try do
      :ok = :logger.set_primary_config(:level, :debug)
      fun.()
      :ok = :logger.remove_handler(handler_id)
      File.read!(path)
    after
      :logger.remove_handler(handler_id)
      :logger.set_primary_config(:level, primary_level)
      File.rm(path)
    end
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          title: "HTTP issue",
          url: "https://example.org/issues/MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          thread_id: "thread-http",
          turn_id: "turn-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          recent_codex_events: [
            %{
              event: :manager_steer_delivered,
              message: "Keep the PR focused.",
              raw: %{"id" => 10_123, "result" => %{"turnId" => "turn-http"}},
              session_id: "thread-http",
              thread_id: "thread-http",
              turn_id: "turn-http",
              timestamp: ~U[2026-01-01 00:00:00Z]
            },
            %{
              event: :notification,
              message: %{
                "method" => "item/completed",
                "params" => %{"item" => %{"id" => "msg-static", "type" => "agentMessage", "text" => "Agent update complete."}}
              },
              raw: %{
                "method" => "item/completed",
                "params" => %{"item" => %{"id" => "msg-static", "type" => "agentMessage", "text" => "Agent update complete."}}
              },
              session_id: "thread-http",
              thread_id: "thread-http",
              turn_id: "turn-http",
              timestamp: ~U[2026-01-01 00:00:01Z]
            }
          ],
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom",
          error_kind: "linear_transport"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp agent_delta_event(item_id, delta, timestamp) do
    %{
      event: :notification,
      message: %{"method" => "item/agentMessage/delta", "params" => %{"itemId" => item_id, "delta" => delta}},
      raw: %{"method" => "item/agentMessage/delta", "params" => %{"itemId" => item_id, "delta" => delta}},
      session_id: "thread-http",
      thread_id: "thread-http",
      turn_id: "turn-http",
      timestamp: timestamp
    }
  end

  defp agent_completed_event(item_id, text, timestamp) do
    %{
      event: :notification,
      message: %{"method" => "item/completed", "params" => %{"item" => %{"id" => item_id, "type" => "agentMessage", "text" => text}}},
      raw: %{"method" => "item/completed", "params" => %{"item" => %{"id" => item_id, "type" => "agentMessage", "text" => text}}},
      session_id: "thread-http",
      thread_id: "thread-http",
      turn_id: "turn-http",
      timestamp: timestamp
    }
  end

  defp command_event(method, params, timestamp) do
    %{
      event: :notification,
      message: %{"method" => method, "params" => params},
      raw: %{"method" => method, "params" => params},
      session_id: "thread-http",
      thread_id: "thread-http",
      turn_id: "turn-http",
      timestamp: timestamp
    }
  end

  defp raw_json_event(method, params, timestamp) do
    message = %{"method" => method, "params" => params}

    %{
      event: :notification,
      message: message,
      raw: Jason.encode!(message),
      session_id: "thread-http",
      thread_id: "thread-http",
      turn_id: "turn-http",
      timestamp: timestamp
    }
  end

  defp worker_api_snapshot(overrides \\ %{}) do
    running =
      %{
        issue_id: "issue-api",
        identifier: "MT-API",
        title: "Worker API issue",
        url: "https://example.org/issues/MT-API",
        state: "In Progress",
        session_id: "session-api",
        thread_id: "thread-api",
        turn_id: "turn-api",
        turn_count: 3,
        codex_input_tokens: 10,
        codex_output_tokens: 20,
        codex_total_tokens: 30,
        codex_rate_limits: %{"primary" => %{"remaining" => 42}},
        codex_rate_limits_updated_at: ~U[2026-01-01 00:00:05Z],
        last_codex_message: "rendered",
        last_codex_timestamp: ~U[2026-01-01 00:00:05Z],
        last_codex_event: :notification,
        recent_codex_events: [
          notification_event("item/agentMessage/delta", %{"textDelta" => "Hello "}, 1),
          notification_event("item/agentMessage/delta", %{"textDelta" => "OPENAI_API_KEY=sk-live-secret"}, 2),
          %{
            event: :manager_steer_delivered,
            message: "Keep going",
            raw: %{"result" => %{"turnId" => "turn-api"}},
            session_id: "session-api",
            thread_id: "thread-api",
            turn_id: "turn-api",
            timestamp: ~U[2026-01-01 00:00:03Z]
          },
          notification_event("item/commandExecution/outputDelta", %{"outputDelta" => "mix test\n"}, 4)
        ],
        started_at: ~U[2026-01-01 00:00:00Z]
      }
      |> Map.merge(overrides)

    %{
      running: [running],
      retrying: [],
      codex_totals: %{input_tokens: 10, output_tokens: 20, total_tokens: 30, seconds_running: 5.0},
      rate_limits: %{"primary" => %{"remaining" => 99}}
    }
  end

  defp retry_worker_api_snapshot do
    %{
      running: [],
      retrying: [
        %{
          issue_id: "issue-retry-api",
          identifier: "MT-RETRY-API",
          title: "Retry worker API issue",
          url: "https://example.org/issues/MT-RETRY-API",
          state: "In Progress",
          branch_name: "codex/alb-42-worker-apis",
          workspace_path: Path.join(Config.settings!().workspace.root, "MT-RETRY-API"),
          attempt: 2,
          due_in_ms: 1_500,
          error: "OPENAI_API_KEY=sk-live-secret",
          error_kind: "codex_exit"
        }
      ],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0},
      rate_limits: %{}
    }
  end

  defp timeline_type_events do
    [
      %{
        event: :manager_steer_delivered,
        message: "Keep going",
        raw: %{"result" => %{"turnId" => "turn-api"}},
        session_id: "session-api",
        thread_id: "thread-api",
        turn_id: "turn-api",
        timestamp: ~U[2026-01-01 00:00:01Z]
      },
      notification_event("item/agentMessage/delta", %{"textDelta" => "agent message streaming"}, 2),
      notification_event("turn/failed", %{"reason" => "tool failed"}, 3),
      notification_event("item/tool/call", %{"tool" => "shell_command"}, 4),
      notification_event("item/commandExecution/requestApproval", %{"parsedCmd" => "git status"}, 5),
      notification_event("turn/diff/updated", %{"files" => ["notes.txt"]}, 6),
      %{event: :manager_steer_failed, message: "steer failed", raw: %{}, timestamp: ~U[2026-01-01 00:00:07Z]},
      notification_event("turn/completed", %{"usage" => %{"total_tokens" => 10}}, 8),
      %{event: :unexpected_worker_event, message: "unknown", raw: %{}, timestamp: ~U[2026-01-01 00:00:09Z]}
    ]
  end

  defp defensive_timeline_events do
    [
      %{
        event: :tool_call_completed,
        message: "tool finished",
        timestamp: ~U[2026-01-01 00:00:01Z]
      },
      notification_event("item/agentMessage/delta", %{}, 2),
      %{
        event: :manager_steer_delivered,
        message: "",
        raw: %{"manager" => "empty"},
        timestamp: ~U[2026-01-01 00:00:03Z]
      },
      %{
        event: :manager_steer_delivered,
        message: %{"manager" => "map message"},
        raw: %{},
        timestamp: ~U[2026-01-01 00:00:04Z]
      },
      %{
        event: :manager_steer_delivered,
        message: nil,
        raw: nil,
        timestamp: ~U[2026-01-01 00:00:05Z]
      },
      %{
        event: :notification,
        message: %{method: "item/commandExecution/outputDelta", params: %{msg: %{outputDelta: "atom output"}}},
        raw: nil,
        timestamp: ~U[2026-01-01 00:00:06Z]
      },
      %{
        event: :notification,
        message: %{"method" => "item/commandExecution/outputDelta", "params" => "bad params"},
        raw: nil,
        timestamp: ~U[2026-01-01 00:00:07Z]
      },
      %{
        event: "string_event",
        message: nil,
        raw: nil,
        timestamp: ~U[2026-01-01 00:00:08Z]
      }
    ]
  end

  defp notification_event(method, params, sequence) do
    %{
      event: :notification,
      message: %{"method" => method, "params" => Map.put(params, "itemId", "item-#{method}")},
      raw: Jason.encode!(%{"method" => method, "params" => Map.put(params, "itemId", "item-#{method}")}),
      session_id: "session-api",
      thread_id: "thread-api",
      turn_id: "turn-api",
      timestamp: DateTime.add(~U[2026-01-01 00:00:00Z], sequence, :second)
    }
  end

  defp git!(workspace_path, args) do
    case System.cmd("git", ["-C", workspace_path | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp write_transcript_disclosure_rollout!(sessions_root, workspace_path) do
    date_dir = Path.join([sessions_root, "2026", "05", "03"])
    File.mkdir_p!(date_dir)

    rollout_path =
      Path.join(date_dir, "rollout-2026-05-03T10-00-00-#{System.unique_integer([:positive])}.jsonl")

    long_reasoning = "thinking deeply " <> String.duplicate("about preserving disclosure state ", 12)

    lines = [
      %{
        "timestamp" => "2026-05-03T10:00:00Z",
        "type" => "session_meta",
        "payload" => %{
          "id" => "session-disclosure",
          "cwd" => workspace_path,
          "timestamp" => "2026-05-03T10:00:00Z"
        }
      },
      %{
        "timestamp" => "2026-05-03T10:00:01Z",
        "type" => "response_item",
        "payload" => %{"type" => "reasoning", "text" => long_reasoning}
      },
      %{
        "timestamp" => "2026-05-03T10:00:02Z",
        "type" => "response_item",
        "payload" => %{
          "type" => "function_call",
          "name" => "tool_call",
          "arguments" => %{"command" => "mix test"},
          "call_id" => "call-disclosure"
        }
      }
    ]

    File.write!(rollout_path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
    rollout_path
  end

  defp secret_snapshot do
    snapshot = static_snapshot()

    secret_event = %{
      event: :notification,
      message: %{
        payload: %{
          "method" => "item/commandExecution/outputDelta",
          "params" => %{
            "outputDelta" => "OPENAI_API_KEY=sk-live-secret curl https://user:pass@example.org?token=abc123",
            "authorization" => "Bearer live-token"
          }
        }
      },
      raw: ~s({"api_key":"sk-live-secret","password":"p4ss","access_token":"live-token","url":"https://user:pass@example.org?token=abc123"}),
      session_id: "thread-secret",
      thread_id: "thread-secret",
      turn_id: "turn-secret",
      timestamp: ~U[2026-01-01 00:00:00Z]
    }

    secret_running =
      snapshot.running
      |> List.first()
      |> Map.merge(%{
        identifier: "MT-SECRET",
        session_id: "thread-secret",
        thread_id: "thread-secret",
        turn_id: "turn-secret",
        last_codex_message: secret_event.message,
        recent_codex_events: [secret_event]
      })

    %{snapshot | running: [secret_running]}
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp empty_claim_comments do
    claim_comments([])
  end

  defp claim_comments(nodes) do
    {:ok,
     %{
       "data" => %{
         "issue" => %{
           "comments" => %{
             "nodes" => nodes,
             "pageInfo" => %{"hasNextPage" => false}
           }
         }
       }
     }}
  end

  defp malformed_claim_comments do
    {:ok,
     %{
       "data" => %{
         "issue" => %{
           "comments" => %{
             "nodes" => [
               %{"id" => "noise", "body" => "not a claim", "createdAt" => "not-a-date"},
               %{"id" => "bad-claim", "body" => "## Symphony Claim Lease\nowner: \nclaimed_at: nope", "createdAt" => "nope"},
               %{"id" => "bad-release", "body" => "## Symphony Claim Release\nowner: worker", "createdAt" => "nope"},
               %{}
             ],
             "pageInfo" => %{"hasNextPage" => false}
           }
         }
       }
     }}
  end

  defp signed_claim_body(identifier, owner, token, claimed_at, expires_at) do
    Adapter.claim_body_for_test(identifier, owner, token, claimed_at, expires_at)
  end

  defp signed_release_body(claim_id, owner, token, released_at) do
    Adapter.release_body_for_test(claim_id, owner, token, released_at)
  end

  defp test_hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp flush_graphql_messages do
    receive do
      {:graphql_called, _query, _variables} -> flush_graphql_messages()
    after
      0 -> :ok
    end
  end
end
