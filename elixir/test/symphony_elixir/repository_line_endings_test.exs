defmodule SymphonyElixir.RepositoryLineEndingsTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)

  @lf_paths [
    ".gitattributes",
    ".github/workflows/make-all.yml",
    "elixir/.formatter.exs",
    "elixir/.gitattributes",
    "elixir/mix.exs",
    "elixir/lib/symphony_elixir/orchestrator.ex",
    "elixir/test/symphony_elixir/orchestrator_status_test.exs",
    "elixir/test/support/test_support.exs"
  ]

  test "Git attributes keep formatter inputs LF-normalized on Windows checkouts" do
    {output, 0} = System.cmd("git", ["-C", @repo_root, "check-attr", "eol", "--" | @lf_paths], stderr_to_stdout: true)

    attributes =
      output
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [path, " eol", value] = String.split(line, ":", parts: 3)
        {path, String.trim(value)}
      end)

    for path <- @lf_paths do
      assert attributes[path] == "lf"
    end
  end
end
