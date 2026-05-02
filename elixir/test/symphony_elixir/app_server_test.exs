defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  @symlink_skip_reason SymphonyElixir.TestSupport.symlink_skip_reason()

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server setup replaces stale global workflow env with the test-local workflow path" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stale-global-workflow-#{System.unique_integer([:positive])}"
      )

    try do
      workflow_file = Workflow.workflow_file_path()
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      stale_workflow_file = Path.join([test_root, "removed", "WORKFLOW.md"])

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      Application.put_env(:symphony_elixir, :workflow_file_path, stale_workflow_file)
      Workflow.set_workflow_file_path(workflow_file)

      write_workflow_file!(workflow_file,
        workspace_root: workspace_root
      )

      assert Application.get_env(:symphony_elixir, :workflow_file_path) == workflow_file
      assert Config.settings!().workspace.root == workspace_root

      issue = %Issue{
        id: "issue-stale-workflow-guard",
        identifier: "MT-998",
        title: "Validate stale workflow isolation",
        description: "Ensure app-server uses the test-local workspace root",
        state: "In Progress",
        url: "https://example.org/issues/MT-998",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, root}} =
               AppServer.run(outside_workspace, "guard", issue)

      assert root == Path.expand(workspace_root)
    after
      File.rm_rf(test_root)
    end
  end

  if @symlink_skip_reason, do: @tag(skip: @symlink_skip_reason)

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, rejected_path, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)

      assert SymphonyElixir.TestSupport.normalize_path_for_assertion(rejected_path) ==
               SymphonyElixir.TestSupport.normalize_path_for_assertion(symlink_workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes explicit turn sandbox policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      write_fake_codex!(
        codex_binary,
        [
          ~s({"id":1,"result":{}}),
          ~s({"id":2,"result":{"thread":{"id":"thread-1001"}}}),
          ~s({"id":3,"result":{"turn":{"id":"turn-1001"}}}),
          %{stdout: ~s({"method":"turn/completed"}), exit: 0}
        ],
        trace_env: "SYMP_TEST_CODEx_TRACE",
        default_trace: "/tmp/codex-supported-turn-policies.trace"
      )

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy passthrough",
        description: "Ensure runtime startup forwards configured turn sandbox policies unchanged",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{"type" => "workspaceWrite", "writableRoots" => ["relative/path"], "networkAccess" => true},
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      Enum.each(policy_cases, fn configured_policy ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == configured_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks request-for-input events as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      write_fake_codex!(
        codex_binary,
        [
          ~s({"id":1,"result":{}}),
          ~s({"id":2,"result":{"thread":{"id":"thread-88"}}}),
          ~s({"id":3,"result":{"turn":{"id":"turn-88"}}}),
          ~s({"method":"turn/input_required","id":"resp-1","params":{"requiresInput":true,"reason":"blocked"}})
        ],
        trace_env: "SYMP_TEST_CODEx_TRACE",
        default_trace: "/tmp/codex-input.trace"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: "Cannot satisfy codex input",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs input", issue)

      assert payload["method"] == "turn/input_required"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails when command execution approval is required under safer defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      write_fake_codex!(codex_binary, [
        ~s({"id":1,"result":{}}),
        ~s({"id":2,"result":{"thread":{"id":"thread-89"}}}),
        %{
          stdout: [
            ~s({"id":3,"result":{"turn":{"id":"turn-89"}}}),
            ~s({"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}})
          ]
        },
        %{hold: true}
      ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: "Ensure safer defaults do not auto approve requests",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle approval request", issue)

      assert payload["method"] == "item/commandExecution/requestApproval"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves command execution approval requests when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      write_fake_codex!(
        codex_binary,
        [
          ~s({"id":1,"result":{}}),
          %{},
          ~s({"id":2,"result":{"thread":{"id":"thread-89"}}}),
          %{
            stdout: [
              ~s({"id":3,"result":{"turn":{"id":"turn-89"}}}),
              ~s({"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}})
            ]
          },
          %{stdout: ~s({"method":"turn/completed"}), exit: 0}
        ],
        trace_env: "SYMP_TEST_CODex_TRACE",
        default_trace: "/tmp/codex-auto-approve.trace"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure app-server approval requests are handled automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle approval request", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 1 and
                   get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 2 and
                   case get_in(payload, ["params", "dynamicTools"]) do
                     [
                       %{
                         "description" => description,
                         "inputSchema" => %{"required" => ["query"]},
                         "name" => "linear_graphql"
                       }
                     ] ->
                       description =~ "Linear"

                     _ ->
                       false
                   end
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99 and get_in(payload, ["result", "decision"]) == "acceptForSession"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves MCP tool approval prompts when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-717")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      write_fake_codex!(
        codex_binary,
        [
          ~s({"id":1,"result":{}}),
          %{},
          ~s({"id":2,"result":{"thread":{"id":"thread-717"}}}),
          %{
            stdout: [
              ~s({"id":3,"result":{"turn":{"id":"turn-717"}}}),
              Jason.encode!(%{
                id: 110,
                method: "item/tool/requestUserInput",
                params: %{
                  itemId: "call-717",
                  questions: [
                    %{
                      header: "Approve app tool call?",
                      id: "mcp_tool_call_approval_call-717",
                      isOther: false,
                      isSecret: false,
                      options: [
                        %{description: "Run the tool and continue.", label: "Approve Once"},
                        %{description: "Run the tool and remember this choice for this session.", label: "Approve this Session"},
                        %{description: "Decline this tool call and continue.", label: "Deny"},
                        %{description: "Cancel this tool call", label: "Cancel"}
                      ],
                      question: "The linear MCP server wants to run the tool \"Save issue\", which may modify or delete data. Allow this action?"
                    }
                  ],
                  threadId: "thread-717",
                  turnId: "turn-717"
                }
              })
            ]
          },
          %{stdout: ~s({"method":"turn/completed"}), exit: 0}
        ],
        trace_env: "SYMP_TEST_CODEx_TRACE",
        default_trace: "/tmp/codex-tool-user-input-auto-approve.trace"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Auto approve MCP tool request user input",
        description: "Ensure app tool approval prompts continue automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle tool approval prompt", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110 and
                   get_in(payload, ["result", "answers", "mcp_tool_call_approval_call-717", "answers"]) ==
                     ["Approve this Session"]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends a generic non-interactive answer for freeform tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-718")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      write_fake_codex!(codex_binary, [
        ~s({"id":1,"result":{}}),
        %{},
        ~s({"id":2,"result":{"thread":{"id":"thread-718"}}}),
        %{
          stdout: [
            ~s({"id":3,"result":{"turn":{"id":"turn-718"}}}),
            ~s({"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}})
          ]
        },
        %{stdout: ~s({"method":"turn/completed"}), exit: 0}
      ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts receive a generic answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-718",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle generic tool input", issue, on_message: on_message)

      assert_received {:app_server_message,
                       %{
                         event: :tool_input_auto_answered,
                         answer: "This is a non-interactive session. Operator input is unavailable."
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends a generic non-interactive answer for option-based tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-options-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-options.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      write_fake_codex!(
        codex_binary,
        [
          ~s({"id":1,"result":{}}),
          %{},
          ~s({"id":2,"result":{"thread":{"id":"thread-719"}}}),
          %{
            stdout: [
              ~s({"id":3,"result":{"turn":{"id":"turn-719"}}}),
              ~s({"id":112,"method":"item/tool/requestUserInput","params":{"itemId":"call-719","questions":[{"header":"Choose an action","id":"options-719","isOther":false,"isSecret":false,"options":[{"description":"Use the default behavior.","label":"Use default"},{"description":"Skip this step.","label":"Skip"}],"question":"How should I proceed?"}],"threadId":"thread-719","turnId":"turn-719"}})
            ]
          },
          %{stdout: ~s({"method":"turn/completed"}), exit: 0}
        ],
        trace_env: "SYMP_TEST_CODEx_TRACE",
        default_trace: "/tmp/codex-tool-user-input-options.trace"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input answer",
        description: "Ensure option prompts receive a generic non-interactive answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle option based tool input", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 112 and
                   get_in(payload, ["result", "answers", "options-719", "answers"]) == [
                     "This is a non-interactive session. Operator input is unavailable."
                   ]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends manager steer messages to the active turn with expected turn id" do
    do_test_app_server_sends_manager_steer_messages_to_the_active_turn()
  end

  test "app server records manager steer rejection responses from codex" do
    do_test_app_server_records_manager_steer_rejection_response()
  end

  defp do_test_app_server_records_manager_steer_rejection_response do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-steer-reject-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-721")
      codex_binary = Path.join(test_root, "fake-codex")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      File.mkdir_p!(workspace)

      write_fake_codex!(codex_binary, [
        ~s({"id":1,"result":{}}),
        %{},
        ~s({"id":2,"result":{"thread":{"id":"thread-721"}}}),
        ~s({"id":3,"result":{"turn":{"id":"turn-721"}}}),
        %{
          reply_error: %{"code" => "turn_not_running", "message" => "turn stopped"},
          stdout: ~s({"method":"turn/completed"}),
          exit: 0
        }
      ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-steer-reject",
        identifier: "MT-721",
        title: "Steer rejected turn",
        description: "Record app-server steer rejection",
        state: "In Progress",
        url: "https://example.org/issues/MT-721",
        labels: ["backend"]
      }

      parent = self()
      on_message = fn message -> send(parent, {:app_server_message, message}) end

      task =
        Task.async(fn ->
          {:ok, session} = AppServer.start_session(workspace)

          try do
            AppServer.run_turn(session, "Wait for manager steer rejection", issue, on_message: on_message)
          after
            AppServer.stop_session(session)
          end
        end)

      assert_receive {:app_server_message, %{event: :session_started, session_id: "thread-721-turn-721"}},
                     1_000

      request_ref = make_ref()
      send(task.pid, {:codex_steer, self(), request_ref, "thread-721-turn-721", "Retry the focused test."})
      assert_receive {:codex_steer_request_result, ^request_ref, {:ok, "thread-721-turn-721"}}, 1_000

      assert {:ok, _result} = Task.await(task, 1_000)

      assert_receive {:app_server_message,
                      %{
                        event: :manager_steer_failed,
                        session_id: "thread-721-turn-721",
                        reason: %{"code" => "turn_not_running", "message" => "turn stopped"}
                      }},
                     1_000
    after
      File.rm_rf(test_root)
    end
  end

  defp do_test_app_server_sends_manager_steer_messages_to_the_active_turn do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-steer-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-720")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-steer.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      write_fake_codex!(
        codex_binary,
        [
          ~s({"id":1,"result":{}}),
          %{},
          ~s({"id":2,"result":{"thread":{"id":"thread-720"}}}),
          ~s({"id":3,"result":{"turn":{"id":"turn-720"}}}),
          %{reply_result: %{"turnId" => "turn-720"}, stdout: ~s({"method":"turn/completed"}), exit: 0}
        ],
        trace_env: "SYMP_TEST_CODEx_TRACE",
        default_trace: "/tmp/codex-steer.trace"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-steer",
        identifier: "MT-720",
        title: "Steer active turn",
        description: "Ensure manager steering uses the app-server steer method",
        state: "In Progress",
        url: "https://example.org/issues/MT-720",
        labels: ["backend"]
      }

      parent = self()
      on_message = fn message -> send(parent, {:app_server_message, message}) end

      task =
        Task.async(fn ->
          {:ok, session} = AppServer.start_session(workspace)

          try do
            AppServer.run_turn(session, "Wait for manager steer", issue, on_message: on_message)
          after
            AppServer.stop_session(session)
          end
        end)

      assert_receive {:app_server_message, %{event: :session_started, session_id: "thread-720-turn-720"}},
                     1_000

      request_ref = make_ref()
      send(task.pid, {:codex_steer, self(), request_ref, "thread-720-turn-720", "Focus on the failing API test."})
      assert_receive {:codex_steer_request_result, ^request_ref, {:ok, "thread-720-turn-720"}}, 1_000

      assert {:ok, _result} = Task.await(task, 1_000)

      assert_receive {:app_server_message,
                      %{
                        event: :manager_steer_delivered,
                        session_id: "thread-720-turn-720",
                        thread_id: "thread-720",
                        turn_id: "turn-720",
                        message: "Focus on the failing API test."
                      }},
                     1_000

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["method"] == "turn/steer" and
                   get_in(payload, ["params", "threadId"]) == "thread-720" and
                   get_in(payload, ["params", "expectedTurnId"]) == "turn-720" and
                   get_in(payload, ["params", "input"]) == [
                     %{"type" => "text", "text" => "Focus on the failing API test."}
                   ]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      write_fake_codex!(
        codex_binary,
        [
          ~s({"id":1,"result":{}}),
          %{},
          ~s({"id":2,"result":{"thread":{"id":"thread-90"}}}),
          %{
            stdout: [
              ~s({"id":3,"result":{"turn":{"id":"turn-90"}}}),
              ~s({"id":101,"method":"item/tool/call","params":{"tool":"some_tool","callId":"call-90","threadId":"thread-90","turnId":"turn-90","arguments":{}}})
            ]
          },
          %{stdout: ~s({"method":"turn/completed"}), exit: 0}
        ],
        trace_env: "SYMP_TEST_CODEx_TRACE",
        default_trace: "/tmp/codex-tool-call.trace"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Reject unsupported tool calls", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 101 and
                   get_in(payload, ["result", "success"]) == false and
                   String.contains?(
                     get_in(payload, ["result", "output"]),
                     "Unsupported dynamic tool"
                   )
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      write_fake_codex!(
        codex_binary,
        [
          ~s({"id":1,"result":{}}),
          %{},
          ~s({"id":2,"result":{"thread":{"id":"thread-90a"}}}),
          %{
            stdout: [
              ~s({"id":3,"result":{"turn":{"id":"turn-90a"}}}),
              ~s({"id":102,"method":"item/tool/call","params":{"name":"linear_graphql","callId":"call-90a","threadId":"thread-90a","turnId":"turn-90a","arguments":{"query":"query Viewer { viewer { id } }","variables":{"includeTeams":false}}}})
            ]
          },
          %{stdout: ~s({"method":"turn/completed"}), exit: 0}
        ],
        trace_env: "SYMP_TEST_CODEx_TRACE",
        default_trace: "/tmp/codex-supported-tool-call.trace"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        url: "https://example.org/issues/MT-90A",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => true,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue, tool_executor: tool_executor)

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "output"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits tool_call_failed for supported tool failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90B")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call-failed.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      write_fake_codex!(
        codex_binary,
        [
          ~s({"id":1,"result":{}}),
          %{},
          ~s({"id":2,"result":{"thread":{"id":"thread-90b"}}}),
          %{
            stdout: [
              ~s({"id":3,"result":{"turn":{"id":"turn-90b"}}}),
              ~s({"id":103,"method":"item/tool/call","params":{"tool":"linear_graphql","callId":"call-90b","threadId":"thread-90b","turnId":"turn-90b","arguments":{"query":"query Viewer { viewer { id } }"}}})
            ]
          },
          %{stdout: ~s({"method":"turn/completed"}), exit: 0}
        ],
        trace_env: "SYMP_TEST_CODEx_TRACE",
        default_trace: "/tmp/codex-tool-call-failed.trace"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        url: "https://example.org/issues/MT-90B",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"error":{"message":"boom"}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle failed tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql", %{"query" => "query Viewer { viewer { id } }"}}

      assert_received {:app_server_message, %{event: :tool_call_failed, payload: %{"params" => %{"tool" => "linear_graphql"}}}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      write_fake_codex!(codex_binary, [
        ~s({"id":1,"result":{},"padding":"#{String.duplicate("a", 1_100_000)}"}),
        ~s({"id":2,"result":{"thread":{"id":"thread-91"}}}),
        ~s({"id":3,"result":{"turn":{"id":"turn-91"}}}),
        %{stdout: ~s({"method":"turn/completed"}), exit: 0}
      ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server captures codex side output and logs it through Logger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      write_fake_codex!(codex_binary, [
        ~s({"id":1,"result":{}}),
        ~s({"id":2,"result":{"thread":{"id":"thread-92"}}}),
        ~s({"id":3,"result":{"turn":{"id":"turn-92"}}}),
        %{stderr: "warning: this is stderr noise", stdout: ~s({"method":"turn/completed"}), exit: 0}
      ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      assert log =~ "Codex turn stream output: warning: this is stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server strict stdio mode rejects non-json startup output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-strict-stdio-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-STRICT")
      codex_script = Path.join(test_root, "fake-codex.js")
      File.mkdir_p!(workspace)

      File.write!(codex_script, """
      process.stdout.write("startup banner\\n");

      process.stdin.on("data", chunk => {
        const line = chunk.toString();

        if (line.includes('"id":1')) {
          process.stdout.write('{"id":1,"result":{}}\\n');
        } else if (line.includes('"id":2')) {
          process.stdout.write('{"id":2,"result":{"thread":{"id":"thread-strict"}}}\\n');
        } else {
          process.exit(0);
        }
      });
      """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "node #{codex_script} app-server"
      )

      assert {:error, {:non_json_stdio, "startup banner"}} =
               AppServer.start_session(workspace, strict_stdio: true)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits malformed events for JSON-like protocol lines that fail to decode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-protocol-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      write_fake_codex!(codex_binary, [
        ~s({"id":1,"result":{}}),
        ~s({"id":2,"result":{"thread":{"id":"thread-93"}}}),
        ~s({"id":3,"result":{"turn":{"id":"turn-93"}}}),
        %{stdout: [~s({"method":"turn/completed"), ~s({"method":"turn/completed"})], exit: 0}
      ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-malformed-protocol",
        identifier: "MT-93",
        title: "Malformed protocol frame",
        description: "Ensure malformed JSON-like frames are surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Capture malformed protocol line", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: "{\"method\":\"turn/completed\""}}
      assert_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  if SymphonyElixir.TestSupport.windows?() do
    @tag skip: "Remote SSH app-server startup shells through real ssh.exe; this Unix fake exercises argv construction only."
  end

  test "app server launches over ssh for remote workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-ssh-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> SymphonyElixir.TestSupport.path_separator() <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      count=0
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        codex_command: "fake-remote-codex app-server"
      )

      issue = %Issue{
        id: "issue-remote",
        identifier: "MT-REMOTE",
        title: "Run remote app server",
        description: "Validate ssh-backed codex startup",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Run remote worker",
                 issue,
                 worker_host: "worker-01:2200"
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
      assert argv_line =~ "-T -p 2200 worker-01 bash -lc"
      assert argv_line =~ "cd "
      assert argv_line =~ remote_workspace
      assert argv_line =~ "exec "
      assert argv_line =~ "fake-remote-codex app-server"

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
