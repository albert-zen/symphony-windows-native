defmodule SymphonyElixir.Codex.ValidationEvidenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.ValidationEvidence

  test "requires a Test Plan section" do
    body = """
    #### Summary

    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "PR body must include a Test Plan section with local validation evidence."
           ]
  end

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

  test "reports skipped heavy validation without a reason" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all`
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must explain why the heavy local validation check was not run."
           ]
  end

  test "rejects skipped heavy validation that only restates it was not run" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must explain why the heavy local validation check was not run."
           ]
  end

  test "rejects skipped heavy validation with because plus only skip wording" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because skipped.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must explain why the heavy local validation check was not run."
           ]
  end

  test "rejects bare inability words as skipped heavy validation reasons" do
    for word <- ["cannot", "can't", "unable", "unavailable"] do
      body = """
      #### Test Plan

      - [ ] `make -C elixir all` #{word}.
      - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
      """

      assert ValidationEvidence.lint_pr_body(body) == [
               "Test Plan must explain why the heavy local validation check was not run."
             ]
    end
  end

  test "rejects inability words as because and due to reasons" do
    for reason <- ["because cannot", "because can't", "because unable", "because unavailable", "due to unavailable"] do
      body = """
      #### Test Plan

      - [ ] `make -C elixir all` not run locally #{reason}.
      - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
      """

      assert ValidationEvidence.lint_pr_body(body) == [
               "Test Plan must explain why the heavy local validation check was not run."
             ]
    end
  end

  test "rejects filler-only inability phrases" do
    for reason <- ["cannot run", "unable to run", "unavailable to run"] do
      body = """
      #### Test Plan

      - [ ] `make -C elixir all` #{reason}.
      - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
      """

      assert ValidationEvidence.lint_pr_body(body) == [
               "Test Plan must explain why the heavy local validation check was not run."
             ]
    end
  end

  test "accepts concrete inability reason for skipped heavy validation" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` unavailable while the Windows-only shell profile is isolated in CI.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == []
  end

  test "accepts justified skipped heavy validation with narrower local evidence" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because the full gate is unavailable.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == []
  end

  test "accepts make.cmd all as the heavy local validation gate" do
    body = """
    #### Test Plan

    - [x] `make.cmd all` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == []
  end

  test "rejects checked commands that only delegate validation to CI" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because this test checks CI-only evidence rejection.
    - [x] `ruff` in CI.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check.",
             "Test Plan must name narrower local validation when the heavy check is skipped."
           ]
  end

  test "rejects CI inspection commands as local validation evidence" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because only CI failure inspection was needed.
    - [x] `gh run view 25243442043 --log-failed` used locally to inspect CI failure evidence.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check.",
             "Test Plan must name narrower local validation when the heavy check is skipped."
           ]
  end

  test "rejects gh pr checks as local validation evidence" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because only CI failure inspection was needed.
    - [x] `gh pr checks 57` used locally to inspect CI failure evidence.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check.",
             "Test Plan must name narrower local validation when the heavy check is skipped."
           ]
  end

  test "rejects checked backticked prose that is not a validation command" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because this test checks non-command evidence rejection.
    - [x] `README.md passed locally`
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check.",
             "Test Plan must name narrower local validation when the heavy check is skipped."
           ]
  end

  test "rejects checked validation commands reported as unsuccessful" do
    for result <- ["failed locally", "errored locally", "timed out locally", "canceled locally", "cancelled locally"] do
      body = """
      #### Test Plan

      - [ ] `make -C elixir all` not run locally because this test checks unsuccessful evidence rejection.
      - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` #{result}.
      """

      assert ValidationEvidence.lint_pr_body(body) == [
               "Test Plan must include at least one checked local validation command or targeted check.",
               "Test Plan must name narrower local validation when the heavy check is skipped."
             ]
    end
  end

  test "rejects checked heavy validation reported as unsuccessful" do
    body = """
    #### Test Plan

    - [x] `make -C elixir all` failed locally.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must explain why the heavy local validation check was not run."
           ]
  end

  test "accepts unbackticked targeted validation commands" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because this change only touched validation evidence parsing.
    - [x] mix test test/symphony_elixir/validation_evidence_test.exs passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == []
  end

  test "rejects targeted local evidence without heavy validation or skip justification" do
    body = """
    #### Test Plan

    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must explain why the heavy local validation check was not run."
           ]
  end

  test "rejects validation commands reported only from CI" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because CI reported the broader gate.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed in CI.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check.",
             "Test Plan must name narrower local validation when the heavy check is skipped."
           ]
  end

  test "rejects validation commands reported as results from CI" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because CI reported the broader gate.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` results from CI.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check.",
             "Test Plan must name narrower local validation when the heavy check is skipped."
           ]
  end

  test "rejects checked heavy validation reported only from CI" do
    body = """
    #### Test Plan

    - [x] `make -C elixir all` passed in CI.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must explain why the heavy local validation check was not run."
           ]
  end

  test "rejects checked heavy validation reported as CI-only" do
    body = """
    #### Test Plan

    - [x] `make -C elixir all` CI-only.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must explain why the heavy local validation check was not run."
           ]
  end

  test "rejects checked make-all reported only from CI" do
    body = """
    #### Test Plan

    - [x] `make-all` passed in CI.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must explain why the heavy local validation check was not run."
           ]
  end

  test "rejects validation commands reported as GitHub Actions results" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because GitHub Actions reported the broader gate.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` results from GitHub Actions.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check.",
             "Test Plan must name narrower local validation when the heavy check is skipped."
           ]
  end

  test "rejects validation commands where CI is the actor" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because GitHub Actions reported the broader gate.
    - [x] CI ran `mix test test/symphony_elixir/validation_evidence_test.exs`.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check.",
             "Test Plan must name narrower local validation when the heavy check is skipped."
           ]
  end

  test "rejects validation commands under CI status labels" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because CI reported the broader gate.
    - [x] CI: `mix test test/symphony_elixir/validation_evidence_test.exs` passed.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check.",
             "Test Plan must name narrower local validation when the heavy check is skipped."
           ]
  end

  test "rejects validation commands where CI uses another actor verb" do
    body = """
    #### Test Plan

    - [ ] `make -C elixir all` not run locally because CI reported the broader gate.
    - [x] CI executed `mix test test/symphony_elixir/validation_evidence_test.exs` successfully.
    """

    assert ValidationEvidence.lint_pr_body(body) == [
             "Test Plan must include at least one checked local validation command or targeted check.",
             "Test Plan must name narrower local validation when the heavy check is skipped."
           ]
  end

  test "stops Test Plan parsing at the next markdown heading" do
    body = """
    #### Test Plan

    - [x] `make -C elixir all` passed locally.
    - [x] `mix test test/symphony_elixir/validation_evidence_test.exs` passed locally.

    #### Notes

    - [ ] `make -C elixir all`
    """

    assert ValidationEvidence.lint_pr_body(body) == []
  end
end
