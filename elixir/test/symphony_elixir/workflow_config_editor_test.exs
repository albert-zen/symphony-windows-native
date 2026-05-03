defmodule SymphonyElixir.WorkflowConfigEditorTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.WorkflowConfigEditor

  test "previews safe workflow edits with a diff and dispatch warning" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 3,
      polling_interval_ms: 5_000,
      max_turns: 20,
      tracker_dispatch_states: ["Todo"]
    )

    assert {:ok, preview} =
             WorkflowConfigEditor.preview(%{
               "agent.max_concurrent_agents" => "5",
               "polling.interval_ms" => "10000",
               "agent.max_turns" => "30",
               "tracker.dispatch_states" => "Todo\nReady"
             })

    assert preview.changed_fields == [
             "agent.max_concurrent_agents",
             "agent.max_turns",
             "polling.interval_ms",
             "tracker.dispatch_states"
           ]

    assert preview.diff =~ "-  max_concurrent_agents: 3"
    assert preview.diff =~ "+  max_concurrent_agents: 5"
    assert preview.diff =~ "+    - Ready"
    assert Enum.any?(preview.warnings, &String.contains?(&1, "Dispatch states"))
    assert preview.current_hash != preview.proposed_hash
  end

  test "previews no-op edits without a diff" do
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 3)

    assert "agent.max_concurrent_agents" in WorkflowConfigEditor.editable_fields()

    assert {:ok, preview} =
             WorkflowConfigEditor.preview(%{
               "agent.max_concurrent_agents" => "3"
             })

    assert preview.changed_fields == []
    assert preview.diff == ""
    assert preview.current_hash == preview.proposed_hash
  end

  test "previews and applies a full workflow document edit" do
    workflow_path = Workflow.workflow_file_path()
    current = File.read!(workflow_path)
    proposed = String.replace(current, "max_concurrent_agents: 10", "max_concurrent_agents: 4")

    assert {:ok, preview} = WorkflowConfigEditor.preview_content(proposed)
    assert preview.changed_fields == [:full_workflow]
    assert preview.diff =~ "-  max_concurrent_agents: 10"
    assert preview.diff =~ "+  max_concurrent_agents: 4"

    assert {:ok, applied} = WorkflowConfigEditor.apply_content(proposed)
    assert File.exists?(applied.backup_path)
    assert File.read!(workflow_path) == proposed
    assert {:ok, settings} = Config.settings()
    assert settings.agent.max_concurrent_agents == 4
  end

  test "rejects invalid full workflow document edits before writing" do
    workflow_path = Workflow.workflow_file_path()
    current = File.read!(workflow_path)
    invalid = String.replace(current, "max_concurrent_agents: 10", "max_concurrent_agents: 0")

    assert {:error, {:invalid_workflow, {:invalid_workflow_config, message}}} =
             WorkflowConfigEditor.preview_content(invalid)

    assert message =~ "max_concurrent_agents"
    assert File.read!(workflow_path) == current
  end

  test "inserts missing safe fields without rewriting the prompt body" do
    workflow_path = Workflow.workflow_file_path()

    File.write!(workflow_path, """
    ---
    tracker:
      kind: memory
    agent:
    ---

    Keep this prompt exactly.
    """)

    Workflow.set_workflow_file_path(workflow_path)

    assert {:ok, preview} =
             WorkflowConfigEditor.preview(%{
               "agent.max_concurrent_agents" => "2",
               "tracker.dispatch_states" => "Todo\nNeeds:Review"
             })

    assert preview.diff =~ "+  max_concurrent_agents: 2"
    assert preview.diff =~ "+  dispatch_states:"
    assert preview.proposed_content =~ ~s(    - "Needs:Review")
    assert preview.proposed_content =~ "Keep this prompt exactly."
  end

  test "applies safe workflow edits with backup, validation, and prompt preservation" do
    workflow_path = Workflow.workflow_file_path()

    write_workflow_file!(workflow_path,
      tracker_api_token: "$LINEAR_API_KEY",
      max_concurrent_agents: 3,
      polling_interval_ms: 5_000,
      codex_turn_timeout_ms: 3_600_000,
      observability_refresh_ms: 1_000,
      prompt: "Run the flywheel without leaking $LINEAR_API_KEY."
    )

    assert {:ok, applied} =
             WorkflowConfigEditor.apply(%{
               "agent.max_concurrent_agents" => "4",
               "polling.interval_ms" => "7500",
               "codex.turn_timeout_ms" => "1800000",
               "observability.refresh_ms" => "2500"
             })

    assert File.exists?(applied.backup_path)
    assert applied.applied_hash == applied.proposed_hash
    assert applied.previous_hash != applied.applied_hash

    content = File.read!(workflow_path)
    backup = File.read!(applied.backup_path)

    assert content =~ "max_concurrent_agents: 4"
    assert content =~ "interval_ms: 7500"
    assert content =~ "turn_timeout_ms: 1800000"
    assert content =~ "refresh_ms: 2500"
    assert content =~ "Run the flywheel without leaking $LINEAR_API_KEY."
    assert backup =~ "max_concurrent_agents: 3"

    assert {:ok, settings} = Config.settings()
    assert settings.agent.max_concurrent_agents == 4
    assert settings.polling.interval_ms == 7_500
    assert settings.codex.turn_timeout_ms == 1_800_000
    assert settings.observability.refresh_ms == 2_500
  end

  test "rejects unsupported fields and invalid values before writing" do
    workflow_path = Workflow.workflow_file_path()
    before = File.read!(workflow_path)

    assert {:error, {:unsupported_fields, ["tracker.api_key"]}} =
             WorkflowConfigEditor.preview(%{"tracker.api_key" => "sk-secret"})

    assert {:error, {:invalid_field, "agent.max_concurrent_agents", "must be a positive integer"}} =
             WorkflowConfigEditor.preview(%{"agent.max_concurrent_agents" => "0"})

    assert File.read!(workflow_path) == before
  end

  test "rejects malformed workflow files before writing" do
    workflow_path = Workflow.workflow_file_path()

    File.write!(workflow_path, """
    ---
    agent: [
    ---
    Prompt
    """)

    assert {:error, {:invalid_workflow, {:workflow_parse_error, _reason}}} =
             WorkflowConfigEditor.preview(%{"agent.max_concurrent_agents" => "4"})

    File.write!(workflow_path, "not front matter\nPrompt")

    assert {:error, :workflow_front_matter_missing} =
             WorkflowConfigEditor.preview(%{"agent.max_concurrent_agents" => "4"})

    File.write!(workflow_path, """
    ---
    agent:
    """)

    assert {:error, :workflow_front_matter_not_closed} =
             WorkflowConfigEditor.preview(%{"agent.max_concurrent_agents" => "4"})
  end

  test "blocks behavior-changing apply while active workers are running" do
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 3)

    assert {:error, {:active_workers, 2}} =
             WorkflowConfigEditor.apply(%{"agent.max_concurrent_agents" => "4"}, active_workers_count: 2)
  end
end
