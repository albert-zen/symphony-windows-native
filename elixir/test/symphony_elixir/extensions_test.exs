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
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
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
               "host" => nil
             },
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
               }
             ],
             "conversation" => [
               %{
                 "type" => "user",
                 "key" => "manager:2026-01-01T00:00:00Z:turn-http",
                 "at" => "2026-01-01T00:00:00Z",
                 "title" => "Manager",
                 "excerpt" => "Keep the PR focused.",
                 "raw" => [
                   %{
                     "label" => "manager_steer_delivered",
                     "at" => "2026-01-01T00:00:00Z",
                     "excerpt" => "%{\"id\" => 10123, \"result\" => %{\"turnId\" => \"turn-http\"}}",
                     "truncated?" => false
                   }
                 ]
               }
             ],
             "debug" => %{
               "payload_excerpt" => issue_payload["debug"]["payload_excerpt"],
               "payload_truncated?" => issue_payload["debug"]["payload_truncated?"]
             },
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

    assert json_response(post(build_conn(), "/api/v1/MT-HTTP/steer", %{}), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}
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
    assert html =~ "Worker Detail"
    assert html =~ "Conversation"
    assert html =~ "thread-http"
    assert html =~ "Keep the PR focused."
    assert html =~ "Debug JSON"
    assert html =~ "Worker debug payload"
    refute html =~ "Steer worker"
    refute html =~ "Timeline"
    refute html =~ "Raw worker payload"

    render_submit(view, "steer", %{
      "steer" => %{
        "message" => "Use the narrower UI fix.",
        "session_id" => "thread-http"
      }
    })

    assert_received {:steer_worker_called, "MT-HTTP", "Use the narrower UI fix.", "thread-http"}
  end

  test "worker detail projection coalesces streaming deltas and truncates command output" do
    hidden_marker = "TAIL_SHOULD_NOT_RENDER"
    long_output = String.duplicate("a", 2_050) <> hidden_marker <> String.duplicate("b", 600)

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        agent_delta_event("msg-1", "Hello ", ~U[2026-01-01 00:00:00Z]),
        agent_delta_event("msg-1", "manager.", ~U[2026-01-01 00:00:01Z]),
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
    assert [%{"type" => "assistant", "excerpt" => "Hello manager."}, %{"type" => "tool"} = tool] = issue_payload["conversation"]
    assert tool["command"] == "mix test"
    assert tool["status"] == "completed"
    assert tool["output_truncated?"] == true
    assert String.length(tool["output_excerpt"]) == 2_000
    refute Map.has_key?(List.first(issue_payload["conversation"]), "content")
    refute Map.has_key?(tool, "output")

    rendered_payload = inspect(issue_payload, limit: :infinity)
    refute rendered_payload =~ hidden_marker

    {:ok, _view, html} = live(build_conn(), "/workers/MT-HTTP")
    assert html =~ "Hello manager."
    assert html =~ "mix test"
    assert html =~ "[truncated]"
    refute html =~ hidden_marker
  end

  test "worker detail projection reads parsed messages when raw app-server JSON is a string" do
    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        raw_json_event("item/agentMessage/delta", %{"itemId" => "msg-json", "delta" => "Production "}, ~U[2026-01-01 00:00:00Z]),
        raw_json_event("item/agentMessage/delta", %{"itemId" => "msg-json", "delta" => "delta"}, ~U[2026-01-01 00:00:01Z]),
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
    assert [%{"type" => "assistant", "excerpt" => "Production delta"}, %{"type" => "tool"} = tool] = issue_payload["conversation"]
    assert tool["command"] == "mix test"
    assert tool["output_excerpt"] == "ok\n"
  end

  test "worker detail projection handles content deltas and parsed command fields" do
    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        raw_json_event(
          "codex/event/agent_message_content_delta",
          %{"itemId" => "msg-content", "msg" => %{"content" => "Content delta"}},
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

    assert [%{"type" => "assistant", "excerpt" => "Content delta"}, %{"type" => "tool", "command" => "mix specs.check"}] =
             issue_payload["conversation"]
  end

  test "worker detail projection caps many display items" do
    many_events =
      1..160
      |> Enum.map(fn index ->
        %{
          event: :notification,
          message: "system event #{index}",
          raw: %{"index" => index},
          session_id: "thread-http",
          thread_id: "thread-http",
          turn_id: "turn-http",
          timestamp: DateTime.add(~U[2026-01-01 00:00:00Z], index, :second)
        }
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
    refute Enum.any?(issue_payload["conversation"], &(&1["excerpt"] == "system event 1"))
    refute Enum.any?(issue_payload["timeline"], &(&1["message"] == "system event 1"))
    assert List.last(issue_payload["conversation"])["excerpt"] == "system event 160"
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
        %{
          event: :notification,
          message: "recent system event #{index}",
          raw: %{"index" => index},
          session_id: "thread-http",
          thread_id: "thread-http",
          turn_id: "turn-http",
          timestamp: DateTime.add(~U[2026-01-01 00:00:00Z], index, :second)
        }
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
        agent_delta_event("msg-long", long_delta, ~U[2026-01-01 00:00:00Z])
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

  test "worker detail debug excerpts preserve redaction and structural truncation flags" do
    secret = "OPENAI_API_KEY=sk-live-secret"

    many_small_fields =
      1..60
      |> Map.new(fn index -> {"field_#{index}", "value_#{index}"} end)
      |> Map.put("secret", secret)

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :recent_codex_events], [
        command_event(
          "item/started",
          %{"item" => Map.merge(many_small_fields, %{"id" => "cmd-many", "type" => "commandExecution", "command" => "mix test"})},
          ~U[2026-01-01 00:00:00Z]
        )
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
    [%{"raw" => [raw | _]}] = issue_payload["conversation"]

    assert raw["truncated?"] == true
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

    assert [%{"raw" => [list_raw | _]}, %{"raw" => [json_raw | _]}] = issue_payload["conversation"]
    assert list_raw["truncated?"] == true
    assert json_raw["truncated?"] == true
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

    refute html =~ "sk-live-secret"
    refute html =~ "p4ss"
    refute html =~ "live-token"
    refute html =~ "user:pass"
    refute html =~ "token=abc123"
    assert html =~ "[REDACTED]"
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
