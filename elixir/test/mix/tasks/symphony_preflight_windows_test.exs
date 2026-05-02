defmodule Mix.Tasks.SymphonyPreflightWindowsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Symphony.Preflight.Windows

  test "parses capabilities-only JSON arguments with explicit workflow" do
    assert {:ok, "WORKFLOW.optimization.windows.md", [capabilities_only: true, json: true]} =
             Windows.parse_args_for_test(["--capabilities-only", "--json", "WORKFLOW.optimization.windows.md"])
  end

  test "parses default workflow arguments" do
    assert {:ok, "WORKFLOW.md", [capabilities_only: false, json: false]} =
             Windows.parse_args_for_test([])
  end

  test "rejects extra workflow arguments" do
    assert {:error, :usage} = Windows.parse_args_for_test(["one.md", "two.md"])
  end
end
