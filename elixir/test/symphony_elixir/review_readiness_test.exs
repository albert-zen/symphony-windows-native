defmodule SymphonyElixir.Codex.ReviewReadinessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ReviewReadiness

  test "configured guarded states control which Linear transitions require review readiness" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_review_readiness_guarded_states: ["Agent Review"]
    )

    parent = self()
    linear_client = review_state_linear_client(parent)

    github_client = fn url, _opts ->
      send(parent, {:github_called, url})
      {:error, :unexpected_github_call}
    end

    assert {:error, {:review_readiness_rejected, payload}} =
             ReviewReadiness.authorize_linear_graphql(
               state_transition_mutation(),
               %{"issueId" => "issue-1", "stateId" => "state-agent-review"},
               linear_client,
               github_client
             )

    assert payload["error"]["message"] =~ "Linear review readiness transition rejected"
    assert payload["error"]["message"] =~ "no linked GitHub pull request"
    assert_receive {:linear_context_requested, "issue-1"}
    assert_receive {:linear_workpad_created, body}
    assert body =~ "Review readiness transition rejected"
    refute_receive {:github_called, _url}

    assert :ok =
             ReviewReadiness.authorize_linear_graphql(
               state_transition_mutation(),
               %{"issueId" => "issue-1", "stateId" => "state-in-review"},
               linear_client,
               github_client
             )

    assert_receive {:linear_context_requested, "issue-1"}
    refute_receive {:linear_workpad_created, _body}
    refute_receive {:github_called, _url}
  end

  test "default review readiness guard remains In Review for compatibility" do
    parent = self()

    assert {:error, {:review_readiness_rejected, _payload}} =
             ReviewReadiness.authorize_linear_graphql(
               state_transition_mutation(),
               %{"issueId" => "issue-1", "stateId" => "state-in-review"},
               review_state_linear_client(parent),
               fn url, _opts ->
                 send(parent, {:github_called, url})
                 {:error, :unexpected_github_call}
               end
             )

    assert_receive {:linear_context_requested, "issue-1"}
    assert_receive {:linear_workpad_created, _body}
    refute_receive {:github_called, _url}
  end

  test "github_get uses GitHub CLI auth token when env tokens are absent" do
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_gh_token = System.get_env("GH_TOKEN")
    previous_path = System.get_env("PATH")
    test_root = Path.join(System.tmp_dir!(), "symphony-gh-token-#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_root)
    write_fake_gh!(test_root, "cli-token")

    System.delete_env("GITHUB_TOKEN")
    System.delete_env("GH_TOKEN")
    System.put_env("PATH", test_root <> SymphonyElixir.TestSupport.path_separator() <> (previous_path || ""))

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_github_token)
      restore_env("GH_TOKEN", previous_gh_token)
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    {:ok, url, request_task} = capture_http_request!()

    assert {:ok, %{status: 200, body: %{"ok" => true}}} = ReviewReadiness.github_get(url)
    assert {:ok, request} = Task.await(request_task)
    assert request =~ "authorization: bearer cli-token"
  end

  test "github_get prefers env token over GitHub CLI auth token" do
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_gh_token = System.get_env("GH_TOKEN")
    previous_path = System.get_env("PATH")
    test_root = Path.join(System.tmp_dir!(), "symphony-gh-env-token-#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_root)
    write_failing_gh!(test_root)

    System.put_env("GITHUB_TOKEN", "env-token")
    System.delete_env("GH_TOKEN")
    System.put_env("PATH", test_root <> SymphonyElixir.TestSupport.path_separator() <> (previous_path || ""))

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_github_token)
      restore_env("GH_TOKEN", previous_gh_token)
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    {:ok, url, request_task} = capture_http_request!()

    assert {:ok, %{status: 200, body: %{"ok" => true}}} = ReviewReadiness.github_get(url)
    assert {:ok, request} = Task.await(request_task)
    assert request =~ "authorization: bearer env-token"
  end

  test "github_get uses GH_TOKEN before GitHub CLI auth token" do
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_gh_token = System.get_env("GH_TOKEN")
    previous_path = System.get_env("PATH")
    test_root = Path.join(System.tmp_dir!(), "symphony-gh-env-token-#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_root)
    write_failing_gh!(test_root)

    System.delete_env("GITHUB_TOKEN")
    System.put_env("GH_TOKEN", "gh-env-token")
    System.put_env("PATH", test_root <> SymphonyElixir.TestSupport.path_separator() <> (previous_path || ""))

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_github_token)
      restore_env("GH_TOKEN", previous_gh_token)
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    {:ok, url, request_task} = capture_http_request!()

    assert {:ok, %{status: 200, body: %{"ok" => true}}} = ReviewReadiness.github_get(url)
    assert {:ok, request} = Task.await(request_task)
    assert request =~ "authorization: bearer gh-env-token"
  end

  defp write_fake_gh!(dir, token) do
    if SymphonyElixir.TestSupport.windows?() do
      path = Path.join(dir, "gh.cmd")

      File.write!(path, """
      @echo off
      if "%1"=="auth" if "%2"=="token" (
        echo #{token}
        exit /b 0
      )
      exit /b 1
      """)
    else
      path = Path.join(dir, "gh")

      File.write!(path, """
      #!/bin/sh
      if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
        echo #{token}
        exit 0
      fi
      exit 1
      """)

      File.chmod!(path, 0o755)
    end
  end

  defp write_failing_gh!(dir) do
    if SymphonyElixir.TestSupport.windows?() do
      path = Path.join(dir, "gh.cmd")

      File.write!(path, """
      @echo off
      exit /b 1
      """)
    else
      path = Path.join(dir, "gh")

      File.write!(path, """
      #!/bin/sh
      exit 1
      """)

      File.chmod!(path, 0o755)
    end
  end

  defp state_transition_mutation do
    """
    mutation UpdateIssue($issueId: String!, $stateId: String!) {
      issueUpdate(id: $issueId, input: {stateId: $stateId}) {
        success
      }
    }
    """
  end

  defp review_state_linear_client(parent) do
    fn
      query, %{"issueId" => issue_id, "body" => body}, _opts when is_binary(query) ->
        if String.contains?(query, "commentCreate") do
          send(parent, {:linear_workpad_created, body})
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
        else
          {:error, {:unexpected_linear_query, query, issue_id}}
        end

      query, %{"issueId" => issue_id}, _opts when is_binary(query) ->
        if String.contains?(query, "SymphonyReviewReadinessContext") do
          send(parent, {:linear_context_requested, issue_id})
          {:ok, review_state_issue_context(issue_id)}
        else
          {:error, {:unexpected_linear_query, query}}
        end

      query, variables, _opts ->
        {:error, {:unexpected_linear_query, query, variables}}
    end
  end

  defp review_state_issue_context(issue_id) do
    %{
      "data" => %{
        "issue" => %{
          "id" => issue_id,
          "identifier" => "ALB-1",
          "description" => nil,
          "team" => %{
            "states" => %{
              "nodes" => [
                %{"id" => "state-agent-review", "name" => "Agent Review"},
                %{"id" => "state-in-review", "name" => "In Review"}
              ]
            }
          },
          "attachments" => %{"nodes" => []},
          "comments" => %{"nodes" => []}
        }
      }
    }
  end

  defp capture_http_request! do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    task =
      Task.async(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listen_socket, 5_000),
             {:ok, request} <- :gen_tcp.recv(socket, 0, 5_000) do
          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\n",
              "content-type: application/json\r\n",
              "content-length: 11\r\n",
              "connection: close\r\n",
              "\r\n",
              ~s({"ok":true})
            ])

          :gen_tcp.close(socket)
          :gen_tcp.close(listen_socket)
          {:ok, String.downcase(request)}
        end
      end)

    {:ok, "http://127.0.0.1:#{port}/github", task}
  end
end
