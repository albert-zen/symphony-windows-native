# Agent Workflow Domain

Symphony is the Windows-native orchestration service that polls Linear, creates
isolated workspaces, and starts Codex app-server sessions.

## Core Concepts

- Linear project: private operating queue and state machine.
- GitHub issue: durable public spec and acceptance criteria when the work needs
  traceability.
- Linear blocker relation: DAG edge between issue nodes.
- Worker Symphony: dispatcher for implementation work.
- Reviewer Symphony: dispatcher for independent agent review.
- Agent Brief: minimum context contract for autonomous work.
- Codex Worker Note: append-only Linear comment recording one worker round's
  plan, changes, evidence, blockers, and handoff.
- Codex Review Note: append-only Linear comment recording one review round's
  standards/spec findings and state decision.
- Review readiness: guard that prevents premature movement into the machine
  review queue.

## Durable Workflow Docs

- Issue tracker and state machine: `issue-tracker.md`
- Worker and reviewer responsibilities: `worker-model.md`
- Review policy: `review-policy.md`
- Quality gates: `quality-gates.md`
- Artifact paths: `artifact-paths.md`

Older operational docs under `elixir/docs/` should defer to these files when
state names or role boundaries differ.
