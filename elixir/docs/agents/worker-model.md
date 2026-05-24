# Agent Worker Model

This workflow separates shaping, implementation, review, and final acceptance.
Each role owns a different decision surface.

## Roles

- Human manager: aligns on product and architecture intent, shapes specs,
  releases ready DAG nodes, resolves hard decisions, owns final acceptance, and
  handles system-level blockers.
- Worker Symphony instance: polls `Ready for Agent` and `Rework`, starts
  implementer Codex sessions, and enforces implementation handoff discipline.
- Worker Codex agent: implements one scoped issue, validates it, opens a PR,
  records evidence, and moves only to `Agent Review` after readiness passes.
- Reviewer Symphony instance: polls `Agent Review` and starts reviewer Codex
  sessions.
- Reviewer Codex agent: performs review only. It reports findings and moves the
  Linear issue to `Human Review`, `Rework`, `Needs Human Context`, or `Blocked`.
- Codex Worker Note: one append-only human-facing Linear comment per worker
  round whose first line is `## Codex Worker Note`.
- Codex Review Note: one append-only human-facing Linear comment per reviewer
  round whose first line is `## Codex Review Note`.
- `## Symphony Control`: transient runtime-owned system comments for durable
  claim coordination. Control comments are not human progress notes.

## Worker Assignment Packet

The worker prompt must include:

- Linear identifier, title, state, URL, labels, and description.
- Linked GitHub issue or embedded Agent Brief.
- Blocker/dependency summary and current release reason.
- Branch, commit, PR, and worker-note rules.
- Required local and CI validation commands.
- Review readiness destination, normally `Agent Review`.
- Decision policy for safe choices versus human context escalation.

## Worker Return Packet

Before moving to `Agent Review`, the worker must leave:

- a new `## Codex Worker Note` with `Round: <n>`,
- branch name and PR URL,
- final scope summary,
- acceptance criteria status,
- validation commands and outcomes, with log paths when relevant,
- required check status or CI handoff reason,
- reviewer notes and known residual risks,
- blocker or context escalation details when not complete.

## Reviewer Assignment Packet

The reviewer prompt must include:

- Linear issue, prior worker/review notes, PR URL, and diff scope,
- Agent Brief, PRD, DAG node, and acceptance criteria,
- architecture/quality standards and relevant ADRs,
- required validation evidence,
- explicit instruction that reviewer workspace edits are only for local
  verification; reviewers must not push those edits, open implementation PRs, or
  turn exploratory changes into implementation work.

## Decision Policy

Agents should make conservative decisions when the choice is safe, local,
reversible, and does not change product meaning or architecture direction.
Record the decision in the worker or review note for that round.

Agents must move the issue to `Needs Human Context` when a decision affects:

- product behavior or acceptance criteria,
- architecture direction or public interfaces,
- data shape, migration, or irreversible state,
- security, privacy, credentials, or deployment policy,
- quality gate, coverage, review, or merge policy,
- ambiguous scope where multiple reasonable implementations would satisfy
  different intents.

Use `Blocked` only when the work is clear but cannot proceed because of an
external or system condition.

## Conflict Policy

Keep one Linear issue, one branch, and one PR. Do not broaden an active worker
issue to absorb adjacent work. Create or link follow-up issues for discovered
defects outside the assigned scope.

Do not change another worker's branch or workspace unless a manager explicitly
assigns integration or recovery work.
