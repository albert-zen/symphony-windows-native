defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_review_readiness_repository: "albert-zen/symphony-windows-native"
    )

    :ok
  end

  test "tool_specs advertises the linear_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql allows In Review transition when linked PR required checks pass" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{"check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]}
          })
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql allows In Review transition when PR body closes the originating GitHub issue" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_origin_github_issue()),
        github_client:
          github_client(%{
            "pulls/42" => %{
              "body" => "#### Context\n\nImplements the linked spec.\n\nFixes #46",
              "head" => %{"sha" => "abc123"},
              "base" => %{"ref" => "main"}
            },
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{"check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]}
          })
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql allows In Review transition when PR body uses a fully qualified closing keyword" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_origin_github_issue()),
        github_client:
          github_client(%{
            "pulls/42" => %{
              "body" => "#### Context\n\nImplements the linked spec.\n\nFixes albert-zen/symphony-windows-native#46",
              "head" => %{"sha" => "abc123"},
              "base" => %{"ref" => "main"}
            },
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql allows In Review transition when PR body uses colon-form closing keyword" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_origin_github_issue()),
        github_client:
          github_client(%{
            "pulls/42" => %{
              "body" => "#### Context\n\nImplements the linked spec.\n\nFixes: #46",
              "head" => %{"sha" => "abc123"},
              "base" => %{"ref" => "main"}
            },
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql rejects extra trusted repository closing keywords" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_origin_github_issue()),
        github_client:
          github_client(
            passing_review_readiness_responses(%{
              "body" => "#### Context\n\nImplements the linked spec.\n\nFixes #46\nFixes #47"
            })
          )
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "does not have exactly one unambiguous origin GitHub issue"
    assert_received {:workpad_recorded, body}
    assert body =~ "Remove the closing keyword"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql recognizes current Linear GitHub origin markdown" do
    test_pid = self()

    issue =
      issue_with_origin_github_issue()
      |> Map.put("description", "GitHub: [https://github.com/albert-zen/symphony-windows-native/issues/46](<https://github.com/albert-zen/symphony-windows-native/issues/46>)")

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue),
        github_client:
          github_client(%{
            "pulls/42" => %{
              "body" => "#### Context\n\nImplements the linked spec without a closing keyword.",
              "head" => %{"sha" => "abc123"},
              "base" => %{"ref" => "main"}
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "missing a closing keyword for GitHub issue albert-zen/symphony-windows-native#46"
    assert_received {:workpad_recorded, body}
    assert body =~ "Fixes #46"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects In Review transition when PR body does not close the originating GitHub issue" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_origin_github_issue()),
        github_client:
          github_client(%{
            "pulls/42" => %{
              "body" => "#### Context\n\nImplements the linked spec without a closing keyword.",
              "head" => %{"sha" => "abc123"},
              "base" => %{"ref" => "main"}
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "missing a closing keyword for GitHub issue albert-zen/symphony-windows-native#46"
    assert_received {:workpad_recorded, body}
    assert body =~ "Fixes #46"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects In Review transition when attachment origin issue lacks closing keyword" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_origin_github_issue_attachment()),
        github_client:
          github_client(%{
            "pulls/42" => %{
              "body" => "#### Context\n\nImplements the linked spec without a closing keyword.",
              "head" => %{"sha" => "abc123"},
              "base" => %{"ref" => "main"}
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "missing a closing keyword for GitHub issue albert-zen/symphony-windows-native#46"
    assert_received {:workpad_recorded, body}
    assert body =~ "Fixes #46"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql ignores non-trusted repository issue origins" do
    test_pid = self()

    issue =
      issue_with_pr()
      |> Map.put("description", "GitHub issue: https://github.com/elsewhere/symphony-windows-native/issues/46")

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue),
        github_client: github_client(passing_review_readiness_responses(%{"body" => "#### Context\n\nNo closing keyword."}))
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql ignores non-GitHub origin attachments" do
    test_pid = self()

    issue =
      issue_with_pr()
      |> update_in(["attachments", "nodes"], fn attachments ->
        attachments ++ [%{"sourceType" => "url", "url" => "https://example.com/issues/46"}]
      end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue),
        github_client: github_client(passing_review_readiness_responses(%{"body" => "#### Context\n\nNo closing keyword."}))
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql skips closing keyword enforcement for ambiguous origin issue links" do
    test_pid = self()

    issue =
      issue_with_pr()
      |> Map.put(
        "description",
        """
        GitHub issue: https://github.com/albert-zen/symphony-windows-native/issues/46
        GitHub issue: https://github.com/albert-zen/symphony-windows-native/issues/47
        """
      )

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue),
        github_client: github_client(passing_review_readiness_responses(%{"body" => "#### Context\n\nNo closing keyword."}))
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql rejects closing keywords for ambiguous origin issue links" do
    test_pid = self()

    issue =
      issue_with_pr()
      |> Map.put(
        "description",
        """
        GitHub issue: https://github.com/albert-zen/symphony-windows-native/issues/46
        GitHub issue: https://github.com/albert-zen/symphony-windows-native/issues/47
        """
      )

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue),
        github_client: github_client(passing_review_readiness_responses(%{"body" => "#### Context\n\nFixes #46"}))
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "does not have exactly one unambiguous origin GitHub issue"
    assert_received {:workpad_recorded, body}
    assert body =~ "Remove the closing keyword"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects colon-form closing keywords for ambiguous origin issue links" do
    test_pid = self()

    issue =
      issue_with_pr()
      |> Map.put(
        "description",
        """
        GitHub issue: https://github.com/albert-zen/symphony-windows-native/issues/46
        GitHub issue: https://github.com/albert-zen/symphony-windows-native/issues/47
        """
      )

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue),
        github_client: github_client(passing_review_readiness_responses(%{"body" => "#### Context\n\nFixes: #46"}))
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "does not have exactly one unambiguous origin GitHub issue"
    assert_received {:workpad_recorded, body}
    assert body =~ "Remove the closing keyword"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql skips closing keyword enforcement for cross-source origin ambiguity" do
    test_pid = self()

    issue =
      issue_with_origin_github_issue()
      |> update_in(["attachments", "nodes"], fn attachments ->
        attachments ++
          [
            %{
              "sourceType" => "github",
              "title" => "GH #47",
              "url" => "https://github.com/albert-zen/symphony-windows-native/issues/47"
            }
          ]
      end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue),
        github_client: github_client(passing_review_readiness_responses(%{"body" => "#### Context\n\nNo closing keyword."}))
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql rejects closing keywords for reference-only trusted issue links" do
    test_pid = self()

    issue =
      issue_with_pr()
      |> Map.put("description", "Related reference: https://github.com/albert-zen/symphony-windows-native/issues/46")

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue),
        github_client: github_client(passing_review_readiness_responses(%{"body" => "#### Context\n\nFixes #46"}))
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "does not have exactly one unambiguous origin GitHub issue"
    assert_received {:workpad_recorded, body}
    assert body =~ "Remove the closing keyword"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects colon-form closing keywords for reference-only trusted issue links" do
    test_pid = self()

    issue =
      issue_with_pr()
      |> Map.put("description", "Related reference: https://github.com/albert-zen/symphony-windows-native/issues/46")

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue),
        github_client: github_client(passing_review_readiness_responses(%{"body" => "#### Context\n\nFixes: #46"}))
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "does not have exactly one unambiguous origin GitHub issue"
    assert_received {:workpad_recorded, body}
    assert body =~ "Remove the closing keyword"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql does not treat reference-only trusted issue links as origins" do
    test_pid = self()

    issue =
      issue_with_pr()
      |> Map.put("description", "Related reference: https://github.com/albert-zen/symphony-windows-native/issues/46")

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue),
        github_client: github_client(passing_review_readiness_responses(%{"body" => "#### Context\n\nNo closing keyword."}))
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql rejects ambiguous multiple issueUpdate mutations" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation MoveTwo($firstIssueId: String!, $secondIssueId: String!, $stateId: String!) {
            first: issueUpdate(id: $firstIssueId, input: {stateId: $stateId}) { success }
            second: issueUpdate(id: $secondIssueId, input: {stateId: $stateId}) { success }
          }
          """,
          "variables" => %{"firstIssueId" => "issue-1", "secondIssueId" => "issue-2", "stateId" => "state-review"}
        },
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client: fn _url, _opts -> flunk("GitHub should not be checked for ambiguous transitions") end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "multiple issueUpdate mutations"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql detects issueUpdate when GraphQL comments appear before arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation MoveIssueToState($issueId: String!, $stateId: String!) {
            issueUpdate # GraphQL ignored tokens may appear here.
              (id: $issueId, input: {stateId: $stateId}) {
              success
            }
          }
          """,
          "variables" => %{"issueId" => "issue-1", "stateId" => "state-review"}
        },
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{"check_runs" => []}
          })
      )

    assert response["success"] == false
    assert_received {:workpad_recorded, body}
    assert body =~ "make-all=missing"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql ignores fake stateId tokens inside GraphQL block strings" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation MoveIssueToState($issueId: String!, $input: IssueUpdateInput!) {
            issueUpdate(id: $issueId, input: $input) {
              success
            }
            note: attachmentCreate(input: {url: "https://example.invalid", title: \"\"\"
            stateId: "state-todo"
            \"\"\"}) {
              success
            }
          }
          """,
          "variables" => %{"issueId" => "issue-1", "input" => %{"stateId" => "state-review"}}
        },
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123", "ref" => "codex/ALB-19-review-readiness"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{"check_runs" => []}
          })
      )

    assert response["success"] == false
    assert_received {:workpad_recorded, body}
    assert body =~ "make-all=missing"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql supports literal issueUpdate ids without trusting string field contents" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation MoveIssueToState {
            issueUpdate(
              id: "issue-1"
              input: {
                description: "stateId: \\"state-todo\\""
                stateId: "state-review"
              }
            ) {
              success
            }
          }
          """,
          "variables" => %{}
        },
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, nil, nil}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql keeps literal issueUpdate offsets stable when comments appear first" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation MoveIssueToState {
            # spoof: issueUpdate(id: "issue-2", input: {stateId: "state-todo"}) { success }
            issueUpdate(id: "issue-1", input: {stateId: "state-review"}) {
              success
            }
          }
          """,
          "variables" => %{}
        },
        linear_client: review_linear_client(test_pid, issue_with_pr_and_todo_state()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{"check_runs" => []}
          })
      )

    assert response["success"] == false
    assert_received {:workpad_recorded, body}
    assert body =~ "make-all=missing"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql treats UTF-8 BOM as ignored whitespace before issueUpdate arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation MoveIssueToState($issueId: String!, $stateId: String!) {
            issueUpdate﻿(id: $issueId, input: {stateId: $stateId}) {
              success
            }
          }
          """,
          "variables" => %{"issueId" => "issue-1", "stateId" => "state-review"}
        },
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{"check_runs" => []}
          })
      )

    assert response["success"] == false
    assert_received {:workpad_recorded, body}
    assert body =~ "make-all=missing"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql requires matching app identity for app-bound required checks" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{
              "contexts" => ["make-all"],
              "checks" => [%{"context" => "make-all", "app_id" => 12_345}]
            },
            "commits/abc123/status" => %{"statuses" => [%{"context" => "make-all", "state" => "success"}]},
            "commits/abc123/check-runs" => %{
              "check_runs" => [
                %{
                  "name" => "make-all",
                  "status" => "completed",
                  "conclusion" => "success",
                  "app" => %{"id" => 99_999}
                }
              ]
            }
          })
      )

    assert response["success"] == false
    assert_received {:workpad_recorded, body}
    assert body =~ "make-all=check:app_mismatch"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql allows matching app-bound required checks" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{
              "contexts" => ["make-all"],
              "checks" => [%{"context" => "make-all", "app_id" => 12_345}]
            },
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [
                %{
                  "name" => "make-all",
                  "status" => "completed",
                  "conclusion" => "success",
                  "app" => %{"id" => 12_345}
                }
              ]
            }
          })
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql rejects coverage ignore additions for modules changed in the PR" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main", "sha" => "base123"}},
            "pulls/42/files?per_page=100" => [
              %{
                "filename" => "elixir/lib/symphony_elixir/codex/review_readiness.ex",
                "status" => "modified",
                "patch" => "@@ -550,6 +550,7 @@\n+  def changed, do: :ok"
              },
              %{
                "filename" => "elixir/mix.exs",
                "status" => "modified",
                "patch" => """
                @@ -14,6 +14,7 @@
                 test_coverage: [
                   ignore_modules: [
                     SymphonyElixir.Codex.AppServer,
                +    SymphonyElixir.Codex.ReviewReadiness,
                     SymphonyElixir.Codex.DynamicTool
                   ]
                """
              }
            ],
            "compare/base123...main" => %{"ahead_by" => 0, "files" => []},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "coverage ignore additions include modules changed in this PR"
    assert_received {:workpad_recorded, body}
    assert body =~ "SymphonyElixir.Codex.ReviewReadiness"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql matches coverage ignore additions for acronym modules without defmodule patch context" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "pulls/42/files?per_page=100" => [
              %{
                "filename" => "elixir/lib/symphony_elixir/cli.ex",
                "status" => "modified",
                "patch" => "@@ -90,6 +90,7 @@\n+  def changed, do: :ok"
              },
              %{
                "filename" => "elixir/mix.exs",
                "status" => "modified",
                "patch" => """
                @@ -14,6 +14,7 @@
                 test_coverage: [
                   ignore_modules: [
                     SymphonyElixir.Codex.AppServer,
                +    SymphonyElixir.CLI,
                     SymphonyElixir.Codex.DynamicTool
                   ]
                """
              }
            ],
            "compare/base123...main" => %{"ahead_by" => 0, "files" => []},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "SymphonyElixir.CLI"
    assert_received {:workpad_recorded, body}
    assert body =~ "SymphonyElixir.CLI"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects coverage ignore additions for nested modules changed in the same source file" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "pulls/42/files?per_page=100" => [
              %{
                "filename" => "elixir/lib/symphony_elixir/codex/review_readiness.ex",
                "status" => "modified",
                "patch" => "@@ -22,6 +22,7 @@\n+  def hardened?, do: true"
              },
              %{
                "filename" => "elixir/mix.exs",
                "status" => "modified",
                "patch" => """
                @@ -14,6 +14,7 @@
                 test_coverage: [
                   ignore_modules: [
                     SymphonyElixir.Codex.AppServer,
                +    SymphonyElixir.Codex.ReviewReadiness.Nested,
                     SymphonyElixir.Codex.DynamicTool
                   ]
                """
              }
            ],
            "compare/base123...main" => %{"ahead_by" => 0, "files" => []},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "SymphonyElixir.Codex.ReviewReadiness.Nested"
    assert_received {:workpad_recorded, body}
    assert body =~ "SymphonyElixir.Codex.ReviewReadiness.Nested"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects coverage ignore additions when hunk omits test coverage context" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "pulls/42/files?per_page=100" => [
              %{
                "filename" => "elixir/lib/symphony_elixir/codex/review_readiness.ex",
                "status" => "modified",
                "patch" => "@@ -22,6 +22,7 @@\n+  def hardened?, do: true"
              },
              %{
                "filename" => "elixir/mix.exs",
                "status" => "modified",
                "patch" => """
                @@ -16,2 +16,3 @@
                     SymphonyElixir.Codex.AppServer,
                +    SymphonyElixir.Codex.ReviewReadiness,
                     SymphonyElixir.Codex.DynamicTool
                """
              }
            ],
            "compare/base123...main" => %{"ahead_by" => 0, "files" => []},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "SymphonyElixir.Codex.ReviewReadiness"
    assert_received {:workpad_recorded, body}
    assert body =~ "SymphonyElixir.Codex.ReviewReadiness"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects coverage ignore additions with trailing inline comments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "pulls/42/files?per_page=100" => [
              %{
                "filename" => "elixir/lib/symphony_elixir/codex/review_readiness.ex",
                "status" => "modified",
                "patch" => "@@ -22,6 +22,7 @@\n+  def hardened?, do: true"
              },
              %{
                "filename" => "elixir/mix.exs",
                "status" => "modified",
                "patch" => """
                @@ -14,6 +14,7 @@
                 test_coverage: [
                   ignore_modules: [
                     SymphonyElixir.Codex.AppServer,
                +    SymphonyElixir.Codex.ReviewReadiness, # audited later
                     SymphonyElixir.Codex.DynamicTool
                   ]
                """
              }
            ],
            "compare/base123...main" => %{"ahead_by" => 0, "files" => []},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "SymphonyElixir.Codex.ReviewReadiness"
    assert_received {:workpad_recorded, body}
    assert body =~ "SymphonyElixir.Codex.ReviewReadiness"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects quoted Elixir module atoms in coverage ignore additions" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "pulls/42/files?per_page=100" => [
              %{
                "filename" => "elixir/lib/symphony_elixir/codex/review_readiness.ex",
                "status" => "modified",
                "patch" => "@@ -22,6 +22,7 @@\n+  def hardened?, do: true"
              },
              %{
                "filename" => "elixir/mix.exs",
                "status" => "modified",
                "patch" => """
                @@ -14,6 +14,7 @@
                 test_coverage: [
                   ignore_modules: [
                     SymphonyElixir.Codex.AppServer,
                +    :"Elixir.SymphonyElixir.Codex.ReviewReadiness",
                     SymphonyElixir.Codex.DynamicTool
                   ]
                """
              }
            ],
            "compare/base123...main" => %{"ahead_by" => 0, "files" => []},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "Elixir.SymphonyElixir.Codex.ReviewReadiness"
    assert_received {:workpad_recorded, body}
    assert body =~ "Elixir.SymphonyElixir.Codex.ReviewReadiness"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects inline coverage ignore additions" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "pulls/42/files?per_page=100" => [
              %{
                "filename" => "elixir/lib/symphony_elixir/codex/review_readiness.ex",
                "status" => "modified",
                "patch" => "@@ -22,6 +22,7 @@\n+  def hardened?, do: true"
              },
              %{
                "filename" => "elixir/mix.exs",
                "status" => "modified",
                "patch" => """
                @@ -1,1 +1,1 @@
                +test_coverage: [
                +  ignore_modules: [SymphonyElixir.Codex.ReviewReadiness]
                +]
                """
              }
            ],
            "contents/elixir/mix.exs?ref=abc123" =>
              github_content("""
              test_coverage: [
                ignore_modules: [SymphonyElixir.Codex.ReviewReadiness]
              ]
              """),
            "compare/base123...main" => %{"ahead_by" => 0, "files" => []},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "SymphonyElixir.Codex.ReviewReadiness"
    assert_received {:workpad_recorded, body}
    assert body =~ "SymphonyElixir.Codex.ReviewReadiness"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects one-line test coverage ignore additions" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "pulls/42/files?per_page=100" => [
              %{
                "filename" => "elixir/lib/symphony_elixir/codex/review_readiness.ex",
                "status" => "modified",
                "patch" => "@@ -22,6 +22,7 @@\n+  def hardened?, do: true"
              },
              %{
                "filename" => "elixir/mix.exs",
                "status" => "modified",
                "patch" => "@@ -1,1 +1,1 @@\n+test_coverage: [ignore_modules: [SymphonyElixir.Codex.ReviewReadiness]]"
              }
            ],
            "contents/elixir/mix.exs?ref=abc123" => github_content("test_coverage: [ignore_modules: [SymphonyElixir.Codex.ReviewReadiness]]"),
            "compare/base123...main" => %{"ahead_by" => 0, "files" => []},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "SymphonyElixir.Codex.ReviewReadiness"
    assert_received {:workpad_recorded, body}
    assert body =~ "SymphonyElixir.Codex.ReviewReadiness"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql ignores unrelated mix ignore_modules additions outside test coverage" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "pulls/42/files?per_page=100" => [
              %{
                "filename" => "elixir/lib/symphony_elixir/codex/review_readiness.ex",
                "status" => "modified",
                "patch" => "@@ -22,6 +22,7 @@\n+  def hardened?, do: true"
              },
              %{
                "filename" => "elixir/mix.exs",
                "status" => "modified",
                "patch" => """
                @@ -80,6 +80,7 @@
                 custom_lint: [
                   ignore_modules: [
                +    SymphonyElixir.Codex.ReviewReadiness,
                     Some.Other.Module
                   ]
                """
              }
            ],
            "compare/base123...main" => %{"ahead_by" => 0, "files" => []},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql rejects stale PR bases when current base changes overlap PR files" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main", "sha" => "base123"}},
            "pulls/42/files?per_page=100" => [
              %{"filename" => "lib/symphony_elixir/codex/app_server.ex", "status" => "modified", "patch" => ""}
            ],
            "compare/base123...main" => %{
              "ahead_by" => 1,
              "files" => [%{"filename" => "lib/symphony_elixir/codex/app_server.ex", "status" => "modified"}]
            },
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "PR base is stale"
    assert_received {:workpad_recorded, body}
    assert body =~ "lib/symphony_elixir/codex/app_server.ex"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects stale PR bases when base compare file list may be capped" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main", "sha" => "base123"}},
            "pulls/42/files?per_page=100" => [
              %{"filename" => "lib/symphony_elixir/codex/app_server.ex", "status" => "modified", "patch" => ""}
            ],
            "compare/base123...main" => %{
              "ahead_by" => 12,
              "files" =>
                Enum.map(1..300, fn index ->
                  %{"filename" => "lib/current_main/file_#{index}.ex", "status" => "modified"}
                end)
            },
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{
              "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "capped GitHub compare file list"
    assert_received {:workpad_recorded, body}
    assert body =~ "current base branch compare returns 300 files"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects oversized PR file lists instead of partially checking guardrails" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{
              "changed_files" => 101,
              "head" => %{"sha" => "abc123"},
              "base" => %{"ref" => "main", "sha" => "base123"}
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "only verifies the first 100 GitHub PR files"
    assert_received {:workpad_recorded, body}
    assert body =~ "changes 101 files"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql uses configured required checks when branch protection is unavailable" do
    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_review_readiness_repository: "albert-zen/symphony-windows-native",
      codex_review_readiness_required_checks: ["make-all"]
    )

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{"check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]}
          })
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql guards In Review transition when stateId is inside an input variable" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_input_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{"check_runs" => []}
          })
      )

    assert response["success"] == false
    assert_received {:workpad_recorded, body}
    assert body =~ "make-all=missing"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql allows non-state issueUpdate input variables" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation UpdateIssue($issueId: String!, $input: IssueUpdateInput!) {
            issueUpdate(id: $issueId, input: $input) {
              success
            }
          }
          """,
          "variables" => %{"issueId" => "issue-1", "input" => %{"description" => "updated"}}
        },
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client: fn _url, _opts -> flunk("GitHub should not be checked for non-state updates") end
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", nil}
    refute_received {:workpad_recorded, _}
  end

  test "linear_graphql keeps explicit stateId variables strict when stateId is missing" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation MoveIssueToState($issueId: String!, $stateId: String!) {
            issueUpdate(id: $issueId, input: {stateId: $stateId}) {
              success
            }
          }
          """,
          "variables" => %{"issueId" => "issue-1"}
        },
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client: fn _url, _opts -> flunk("GitHub should not be checked when variables are incomplete") end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "GraphQL variable `$stateId` was missing"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql does not trust PR links from agent-mutable comments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_workpad_pr()),
        github_client: fn _url, _opts -> flunk("GitHub should not be checked for comment-only PR links") end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "no linked GitHub pull request was found"
    assert_received {:workpad_recorded, body}
    assert body =~ "no linked GitHub pull request was found"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects PR attachments outside the configured repository" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr("https://github.com/elsewhere/project/pull/42")),
        github_client:
          github_client(%{
            "repos/elsewhere/project/pulls/42" => %{"head" => %{"sha" => "abc123", "ref" => "codex/ALB-19-review-readiness"}, "base" => %{"ref" => "main"}}
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "not the configured trusted repository"
    assert_received {:workpad_recorded, body}
    assert body =~ "not the configured trusted repository"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects same-repository PR attachments for another issue branch" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123", "ref" => "codex/ALB-20-other-work"}, "base" => %{"ref" => "main"}}
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "does not match Linear issue ALB-19"
    assert_received {:workpad_recorded, body}
    assert body =~ "does not match Linear issue ALB-19"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects same-repository PR attachments for prefix-collision issue branches" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123", "ref" => "codex/ALB-190-other-work"}, "base" => %{"ref" => "main"}}
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "does not match Linear issue ALB-19"
    assert_received {:workpad_recorded, body}
    assert body =~ "does not match Linear issue ALB-19"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects fork PR attachments that target the trusted repository" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{
              "head" => %{
                "sha" => "abc123",
                "ref" => "codex/ALB-19-review-readiness",
                "repo" => %{"full_name" => "elsewhere/symphony-windows-native"}
              },
              "base" => %{"ref" => "main"}
            }
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "head repository elsewhere/symphony-windows-native is not the configured trusted repository"
    assert_received {:workpad_recorded, body}
    assert body =~ "head repository elsewhere/symphony-windows-native is not the configured trusted repository"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql URL-encodes protected branch names before fetching required checks" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "release/2026-05"}},
            "branches/release%2F2026-05/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{"check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]}
          })
      )

    assert response["success"] == true
    assert_received {:linear_mutation_allowed, "issue-1", "state-review"}
  end

  test "linear_graphql rejects In Review transition when no linked PR exists and records workpad reason" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_without_pr()),
        github_client: github_client(%{})
      )

    assert response["success"] == false
    payload = Jason.decode!(response["output"])
    assert get_in(payload, ["error", "code"]) == "review_readiness_rejected"
    assert get_in(payload, ["error", "message"]) =~ "no linked GitHub pull request was found"
    assert_received {:workpad_recorded, body}
    assert body =~ "## Codex Workpad"
    assert body =~ "In Review transition rejected"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql rejects In Review transition when required checks are pending" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{"check_runs" => [%{"name" => "make-all", "status" => "in_progress", "conclusion" => nil}]}
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "required GitHub checks are not passing"
    assert_received {:workpad_recorded, body}
    assert body =~ "make-all=check:in_progress"
  end

  test "linear_graphql rejects In Review transition when required checks fail" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => [%{"context" => "make-all", "state" => "failure"}]},
            "commits/abc123/check-runs" => %{"check_runs" => []}
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "required GitHub checks are not passing"
    assert_received {:workpad_recorded, body}
    assert body =~ "make-all=status:failure"
  end

  test "linear_graphql rejects In Review transition when required checks are missing" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client:
          github_client(%{
            "pulls/42" => %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
            "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
            "commits/abc123/status" => %{"statuses" => []},
            "commits/abc123/check-runs" => %{"check_runs" => []}
          })
      )

    assert response["success"] == false
    assert_received {:workpad_recorded, body}
    assert body =~ "make-all=missing"
  end

  test "linear_graphql rejects In Review transition when GitHub readiness is unverifiable" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client: fn _url, _opts -> {:error, :timeout} end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "GitHub readiness could not be verified"
    assert_received {:workpad_recorded, body}
    assert body =~ ":timeout"
  end

  test "linear_graphql rejects agent-supplied manager override for In Review transition" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        review_transition_arguments(%{
          "symphonyManagerOverride" => true,
          "symphonyManagerOverrideReason" => "Manager approved handoff while CI provider is unavailable."
        }),
        linear_client: review_linear_client(test_pid, issue_with_pr()),
        github_client: fn _url, _opts -> flunk("GitHub should not be checked for manager override") end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "manager override cannot be authorized by an agent tool call"
    assert_received {:workpad_recorded, body}
    assert body =~ "manager override cannot be authorized"
    refute_received {:linear_mutation_allowed, _, _}
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  defp review_transition_arguments(extra_variables \\ %{}) do
    %{
      "query" => """
      mutation MoveIssueToState($issueId: String!, $stateId: String!) {
        issueUpdate(id: $issueId, input: {stateId: $stateId}) {
          success
        }
      }
      """,
      "variables" => Map.merge(%{"issueId" => "issue-1", "stateId" => "state-review"}, extra_variables)
    }
  end

  defp review_transition_input_arguments do
    %{
      "query" => """
      mutation MoveIssueToState($issueId: String!, $input: IssueUpdateInput!) {
        issueUpdate(id: $issueId, input: $input) {
          success
        }
      }
      """,
      "variables" => %{"issueId" => "issue-1", "input" => %{"stateId" => "state-review"}}
    }
  end

  defp issue_with_pr(url \\ "https://github.com/albert-zen/symphony-windows-native/pull/42") do
    %{
      "id" => "issue-1",
      "identifier" => "ALB-19",
      "team" => %{"states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}},
      "attachments" => %{"nodes" => [%{"url" => url}]},
      "comments" => %{"nodes" => []}
    }
  end

  defp issue_with_origin_github_issue do
    Map.put(
      issue_with_pr(),
      "description",
      "GitHub issue: https://github.com/albert-zen/symphony-windows-native/issues/46"
    )
  end

  defp issue_with_origin_github_issue_attachment do
    issue_with_pr()
    |> update_in(["attachments", "nodes"], fn attachments ->
      attachments ++
        [
          %{
            "sourceType" => "github",
            "title" => "GH #46",
            "url" => "https://github.com/albert-zen/symphony-windows-native/issues/46"
          }
        ]
    end)
  end

  defp issue_without_pr do
    put_in(issue_with_pr(), ["attachments", "nodes"], [])
  end

  defp issue_with_pr_and_todo_state do
    put_in(issue_with_pr(), ["team", "states", "nodes"], [
      %{"id" => "state-todo", "name" => "Todo"},
      %{"id" => "state-review", "name" => "In Review"}
    ])
  end

  defp issue_with_workpad_pr do
    issue_with_pr()
    |> put_in(["attachments", "nodes"], [])
    |> put_in(["comments", "nodes"], [
      %{
        "id" => "comment-1",
        "body" => "## Codex Workpad\n\nPR: https://github.com/albert-zen/symphony-windows-native/pull/42"
      }
    ])
  end

  defp review_linear_client(test_pid, issue) do
    fn query, variables, _opts ->
      cond do
        query =~ "SymphonyReviewReadinessContext" ->
          {:ok, %{"data" => %{"issue" => issue}}}

        query =~ "SymphonyReviewReadinessCreateWorkpad" ->
          send(test_pid, {:workpad_recorded, variables["body"]})
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

        query =~ "SymphonyReviewReadinessUpdateWorkpad" ->
          send(test_pid, {:workpad_recorded, variables["body"]})
          {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}

        query =~ "issueUpdate" ->
          state_id = variables["stateId"] || get_in(variables, ["input", "stateId"])
          send(test_pid, {:linear_mutation_allowed, variables["issueId"], state_id})
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end
  end

  defp github_client(responses) do
    fn url, _opts ->
      case github_response(responses, url) do
        {_suffix, payload} -> {:ok, %{status: 200, body: default_pr_payload(url, payload)}}
        nil -> default_github_response(url)
      end
    end
  end

  defp passing_review_readiness_responses(pr_payload) do
    %{
      "pulls/42" =>
        Map.merge(
          %{"head" => %{"sha" => "abc123"}, "base" => %{"ref" => "main"}},
          pr_payload
        ),
      "branches/main/protection/required_status_checks" => %{"contexts" => ["make-all"]},
      "commits/abc123/status" => %{"statuses" => []},
      "commits/abc123/check-runs" => %{
        "check_runs" => [%{"name" => "make-all", "status" => "completed", "conclusion" => "success"}]
      }
    }
  end

  defp default_pr_payload(url, %{"head" => head} = payload) when is_map(head) do
    if String.contains?(url, "/pulls/") do
      default_head =
        head
        |> Map.put_new("ref", "codex/ALB-19-review-readiness")
        |> Map.put_new("repo", %{"full_name" => "albert-zen/symphony-windows-native"})

      default_base =
        payload
        |> Map.get("base", %{})
        |> Map.put_new("ref", "main")
        |> Map.put_new("sha", "base123")

      payload
      |> put_in(["head"], default_head)
      |> put_in(["base"], default_base)
    else
      payload
    end
  end

  defp default_pr_payload(_url, payload), do: payload

  defp default_github_response(url) do
    cond do
      String.ends_with?(url, "/files?per_page=100") ->
        {:ok, %{status: 200, body: []}}

      String.contains?(url, "/contents/elixir/mix.exs?") or String.contains?(url, "/contents/mix.exs?") ->
        {:ok, %{status: 200, body: github_content(mix_exs_head_content())}}

      Regex.match?(~r/\/compare\/[^\/]+\.{3}abc123$/, url) ->
        {:ok, %{status: 200, body: %{"merge_base_commit" => %{"sha" => "base123"}, "files" => []}}}

      String.contains?(url, "/compare/") ->
        {:ok, %{status: 200, body: %{"ahead_by" => 0, "files" => []}}}

      true ->
        {:ok, %{status: 404, body: %{"message" => "not found"}}}
    end
  end

  defp github_content(content) do
    %{"encoding" => "base64", "content" => Base.encode64(content)}
  end

  defp mix_exs_head_content do
    """
    defmodule SymphonyElixir.MixProject do
      use Mix.Project

      def project do
        [
          app: :symphony_elixir,
          version: "0.1.0",
          elixir: "~> 1.19",
          test_coverage: [
            summary: [
              threshold: 100
            ],
            ignore_modules: [
              SymphonyElixir.Codex.AppServer,
              SymphonyElixir.Codex.ReviewReadiness,
              SymphonyElixir.Codex.ReviewReadiness.Nested,
              SymphonyElixir.Codex.DynamicTool,
              SymphonyElixir.CLI
            ]
          ],
          custom_lint: [
            ignore_modules: [
              SymphonyElixir.Codex.ReviewReadiness,
              Some.Other.Module
            ]
          ]
        ]
      end
    end
    """
  end

  defp github_response(responses, url) do
    Enum.find(responses, fn {suffix, _payload} -> String.ends_with?(url, suffix) end)
  end
end
