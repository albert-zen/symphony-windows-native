defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
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
    assert :ok = SymphonyElixir.Tracker.release_issue_claim("issue-1")
    assert :ok = Memory.release_issue_claim("issue-1")
    assert {:error, :invalid_issue_claim} = Memory.acquire_issue_claim(%{})
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_claim_acquired, "issue-1", "MT-1", %{owner: "memory"}}
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
    now = ~U[2026-05-02 00:00:00Z]

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
    assert :ok = Adapter.release_issue_claim("issue-claim")
    assert :ok = Adapter.release_issue_claim("issue-claim", %{})
    assert :ok = Adapter.release_issue_claim("issue-claim", :invalid_claim)

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

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
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
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
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
             "last_error" => nil,
             "tracked" => %{}
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
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
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
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

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
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

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

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
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

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
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
    {:ok,
     %{
       "data" => %{
         "issue" => %{
           "comments" => %{
             "nodes" => [],
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
