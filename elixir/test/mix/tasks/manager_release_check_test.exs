defmodule Mix.Tasks.Symphony.Manager.ReleaseCheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Symphony.Manager.ReleaseCheck

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("symphony.manager.release_check")
    :ok
  end

  test "prints help" do
    output = capture_io(fn -> ReleaseCheck.run(["--help"]) end)

    assert output =~ "mix symphony.manager.release_check --file /path/to/issue.md"
  end

  test "fails when file option is missing" do
    assert_raise Mix.Error, ~r/Missing required option --file/, fn ->
      ReleaseCheck.run([])
    end
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      ReleaseCheck.run(["--wat"])
    end
  end

  test "fails when file is missing" do
    assert_raise Mix.Error, ~r/Unable to read missing.md/, fn ->
      ReleaseCheck.run(["--file", "missing.md"])
    end
  end

  test "passes resolved issue body" do
    in_temp_dir(fn ->
      File.write!("issue.md", """
      ## Dependencies

      - [x] PR #53 merged in `345d606`.
      """)

      output = capture_io(fn -> ReleaseCheck.run(["--file", "issue.md"]) end)

      assert output =~ "Manager release check OK"
    end)
  end

  test "fails unresolved issue body" do
    in_temp_dir(fn ->
      File.write!("issue.md", """
      ## Dependencies

      - Depends on PR #53.
      """)

      error =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/unresolved dependencies/, fn ->
            ReleaseCheck.run(["--file", "issue.md"])
          end
        end)

      assert error =~ "Unresolved dependency on line 3"
    end)
  end

  defp in_temp_dir(fun) do
    root = Path.join(System.tmp_dir!(), "manager-release-check-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    original_cwd = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end
end
