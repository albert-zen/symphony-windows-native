# Agent Artifact Paths

Use these paths as the default locations for durable agent workflow artifacts.

- Architecture canvas: `elixir/docs/agents/canvas.md`
- Visual architecture canvas: `elixir/docs/agents/canvas.html`
- PRDs and specs: `elixir/docs/prd/`
- Issue DAGs: `elixir/docs/implementation/`
- Agent workflow rules: `elixir/docs/agents/`
- Review evidence: Linear worker/review notes, GitHub PR conversation, and PR body
  `Test Plan`
- Runtime evidence: Symphony dashboard, worker detail pages, logs root, and
  linked CI runs

GitHub issues remain the durable public implementation specs when public
traceability is needed. Linear descriptions may mirror the brief but should not
be the only durable source for complex specs.

Do not commit local workflow files that contain private project slugs, tokens,
workspace roots, or repository URLs.
