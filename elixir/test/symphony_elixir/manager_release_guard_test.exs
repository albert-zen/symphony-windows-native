defmodule SymphonyElixir.ManagerReleaseGuardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ManagerReleaseGuard

  test "passes when no dependencies are declared" do
    body = """
    ## Summary

    Ready independent work.
    """

    assert {:ok, []} = ManagerReleaseGuard.check(body)
  end

  test "blocks unresolved dependencies in dependency section" do
    body = """
    ## Dependencies

    - GH #47 / ALB-32 must merge first.
    - [x] GH #81 landed in main.

    ## Acceptance criteria

    Ready after dependency resolution.
    """

    assert {:error, [%{line: 3, text: "- GH #47 / ALB-32 must merge first."}]} =
             ManagerReleaseGuard.check(body)
  end

  test "blocks explicit depends on declarations outside dependency section" do
    body = """
    ## Context

    Depends on: PR #53 merged and runtime redeployed.
    """

    assert {:error, [%{line: 3, text: "Depends on: PR #53 merged and runtime redeployed."}]} =
             ManagerReleaseGuard.check(body)
  end

  test "passes resolved dependency declarations" do
    body = """
    ## Dependencies

    - [x] PR #53 merged in `345d606`.
    - Status: resolved by runtime restart on 2026-05-02.
    - Deployed in PR #81.
    - None.
    """

    assert {:ok, []} = ManagerReleaseGuard.check(body)
  end

  test "blocks future-tense dependency conditions" do
    body = """
    ## Dependencies

    - GH #47 must be merged in main before release.
    - Runtime fix must be deployed in production before release.
    """

    assert {:error, dependencies} = ManagerReleaseGuard.check(body)
    assert Enum.map(dependencies, & &1.line) == [3, 4]
  end

  test "stops dependency section at next heading" do
    body = """
    ## Dependencies

    - [x] PR #53 merged in `345d606`.

    ## Notes

    - This normal bullet is not a dependency.
    """

    assert {:ok, []} = ManagerReleaseGuard.check(body)
  end
end
