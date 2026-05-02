defmodule SymphonyElixir.Codex.ValidationEvidenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.ValidationEvidence

  test "reports skipped heavy validation without narrower local evidence" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because the full gate is unavailable.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check.",
             "Test Plan must name narrower local validation when the heavy check is skipped."
           ]
  end

  test "rejects checked commands that only delegate validation to CI" do
    body = """
    #### Test Plan

    - [x] `ruff` in CI.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check."
           ]
  end

  test "stops Test Plan parsing at the next markdown heading" do
    body = """
    #### Test Plan

    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.

    #### Notes

    - [ ] `make -C elixir all`
    """

    assert ValidationEvidence.lint_pr_body(body) == []
  end
end
