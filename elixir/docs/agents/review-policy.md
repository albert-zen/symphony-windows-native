# Agent Review Policy

Review is split into two axes: standards review and spec review. Passing tests
are required evidence, but they do not prove the issue satisfied the intended
behavior.

## Review States

`Agent Review` is the machine review queue. A worker may move an issue there
only after the linked PR, checks, Workpad, and evidence are review-ready.

`Human Review` means the reviewer agent found no blocking findings and human
acceptance, merge, or final product judgment remains.

`Rework` means the reviewer found blocking findings that a worker can fix
without new human context.

`Needs Human Context` means the reviewer cannot verify success because the spec,
acceptance criteria, dependency state, or decision authority is incomplete.

## Review Axes

Standards Review checks:

- local coding conventions, ADRs, and architecture canvas,
- TDD discipline and behavior-oriented tests,
- deep modules, clear interfaces, locality, leverage, and deletion tests,
- quality gates, coverage policy, stale-base overlap, and PR hygiene,
- whether follow-up defects are filed instead of hidden in logs.

Spec Review checks:

- every acceptance criterion is implemented or explicitly deferred,
- behavior matches the Agent Brief, PRD, and DAG node,
- implementation does not exceed scope,
- required tests and evidence prove the requested behavior,
- unresolved ambiguity is escalated instead of guessed.

## Reviewer Output

Reviewer agents write a concise review result to the Workpad or PR:

```markdown
## Standards Review

### Blocking

### Non-Blocking

### Missing Evidence

## Spec Review

### Blocking

### Non-Blocking

### Missing Evidence
```

Blocking findings must include the file, behavior, standard or requirement
violated, and the required fix. Missing spec context must name the exact human
answer needed.

## Approval Rule

Move to `Human Review` only when both review axes have no blocking findings and
required evidence is present.

Move to `Rework` when the spec is clear and the fix is bounded.

Move to `Needs Human Context` when review exposes unclear intent or a
hard-to-reverse decision.

Move to `Blocked` when review cannot proceed because of GitHub, Linear, Codex,
CI, environment, dependency, or deployment failure.

Reviewer agents do not fix code, broaden scope, or spawn additional workers.
