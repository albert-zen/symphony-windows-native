defmodule Mix.Tasks.PrBody.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.PrBody.Check

  import ExUnit.CaptureIO

  @template """
  #### Context

  <!-- Why is this change needed? -->

  #### TL;DR

  *<!-- A short summary -->*

  #### Summary

  - <!-- Summary bullet -->

  #### Alternatives

  - <!-- Alternative bullet -->

  #### Test Plan

  - [ ] <!-- Test checkbox -->
  """

  @valid_body """
  #### Context

  Context text.

  #### TL;DR

  Short summary.

  #### Summary

  - First change.

  #### Alternatives

  - Alternative considered.

  #### Test Plan

  - [ ] `make -C elixir all` not run locally because this unit test fixture uses targeted validation only.
  - [x] `mix test test/mix/tasks/pr_body_check_test.exs` passed locally.
  """

  setup do
    Mix.Task.reenable("pr_body.check")
    :ok
  end

  test "prints help" do
    output = capture_io(fn -> Check.run(["--help"]) end)
    assert output =~ "mix pr_body.check --file /path/to/pr_body.md"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      Check.run(["lint", "--wat"])
    end
  end

  test "fails when file option is missing" do
    assert_raise Mix.Error, ~r/Missing required option --file/, fn ->
      Check.run(["lint"])
    end
  end

  test "fails when template is missing" do
    in_temp_repo(fn ->
      File.write!("body.md", @valid_body)

      assert_raise Mix.Error, ~r/Unable to read PR template/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  test "fails when template has no headings" do
    in_temp_repo(fn ->
      write_template!("no headings here")
      File.write!("body.md", @valid_body)

      assert_raise Mix.Error, ~r/No markdown headings found/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  test "fails when body file is missing" do
    in_temp_repo(fn ->
      write_template!(@template)

      assert_raise Mix.Error, ~r/Unable to read missing\.md/, fn ->
        Check.run(["lint", "--file", "missing.md"])
      end
    end)
  end

  test "fails when body still has placeholders" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", @template)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "PR description still contains template placeholder comments"
    end)
  end

  test "fails when heading is missing" do
    in_temp_repo(fn ->
      write_template!(@template)

      missing_heading = Regex.replace(~r/#### Alternatives\r?\n\r?\n- Alternative considered\.\r?\n\r?\n/, @valid_body, "")
      File.write!("body.md", missing_heading)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Missing required heading: #### Alternatives"
    end)
  end

  test "fails when headings are out of order" do
    in_temp_repo(fn ->
      write_template!(@template)

      out_of_order = """
      #### TL;DR

      Short summary.

      #### Context

      Context text.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [ ] `make -C elixir all` not run locally because this fixture validates heading order only.
      - [x] Ran targeted checks.
      """

      File.write!("body.md", out_of_order)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Required headings are out of order."
    end)
  end

  test "fails on empty section" do
    in_temp_repo(fn ->
      write_template!(@template)

      empty_context = String.replace(@valid_body, "Context text.", "")
      File.write!("body.md", empty_context)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: #### Context"
    end)
  end

  test "fails when a middle section is blank before the next heading" do
    in_temp_repo(fn ->
      write_template!(@template)

      blank_alternatives = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives


      #### Test Plan

      - [ ] `make -C elixir all` not run locally because this fixture validates section parsing only.
      - [x] Ran targeted checks.
      """

      File.write!("body.md", blank_alternatives)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: #### Alternatives"
    end)
  end

  test "fails when bullet and checkbox expectations are not met" do
    in_temp_repo(fn ->
      write_template!(@template)

      invalid_body = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      Not a bullet.

      #### Alternatives

      Also not a bullet.

      #### Test Plan

      No checkbox.
      """

      File.write!("body.md", invalid_body)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section must include at least one bullet item: #### Summary"
      assert error_output =~ "Section must include at least one bullet item: #### Alternatives"
      assert error_output =~ "Section must include at least one bullet item: #### Test Plan"
      assert error_output =~ "Section must include at least one checkbox item: #### Test Plan"
    end)
  end

  test "fails when heading has no content delimiter" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", "#### Context\nContext text.")

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
          Check.run(["lint", "--file", "body.md"])
        end
      end)
    end)
  end

  test "fails when heading appears at end of file" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", "#### Context")

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: #### Context"
    end)
  end

  test "passes for valid body" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", @valid_body)

      output =
        capture_io(fn ->
          Check.run(["lint", "--file", "body.md"])
        end)

      assert output =~ "PR body format OK"
    end)
  end

  test "fails when Test Plan has no checked local validation evidence" do
    in_temp_repo(fn ->
      write_template!(@template)

      missing_evidence = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [ ] `make -C elixir all`
      - CI will validate this later.
      """

      File.write!("body.md", missing_evidence)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Test Plan must include at least one checked local validation command or targeted check"
    end)
  end

  test "fails when checked Test Plan item only has backticked non-command prose" do
    in_temp_repo(fn ->
      write_template!(@template)

      invalid_evidence = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [x] `README.md passed locally`
      """

      File.write!("body.md", invalid_evidence)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Test Plan must include at least one checked local validation command or targeted check"
    end)
  end

  test "passes with valid targeted local evidence without requiring make all" do
    in_temp_repo(fn ->
      write_template!(@template)

      targeted_evidence = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [ ] `make -C elixir all` not run locally because this test exercises targeted evidence.
      - [x] `mix test test/mix/tasks/pr_body_check_test.exs` passed locally.
      """

      File.write!("body.md", targeted_evidence)

      output =
        capture_io(fn ->
          Check.run(["lint", "--file", "body.md"])
        end)

      assert output =~ "PR body format OK"
    end)
  end

  test "fails when targeted evidence omits heavy validation or skip justification" do
    in_temp_repo(fn ->
      write_template!(@template)

      missing_heavy_gate = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [x] `mix test test/mix/tasks/pr_body_check_test.exs` passed locally.
      """

      File.write!("body.md", missing_heavy_gate)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Test Plan must explain why the heavy local validation check was not run"
    end)
  end

  test "fails when checked validation command only ran in CI" do
    in_temp_repo(fn ->
      write_template!(@template)

      ci_only_evidence = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [ ] `make -C elixir all` not run locally because the full gate is unavailable.
      - [x] `mix test test/mix/tasks/pr_body_check_test.exs` passed in CI.
      """

      File.write!("body.md", ci_only_evidence)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Test Plan must include at least one checked local validation command or targeted check"
    end)
  end

  test "fails when checked validation command reports a local failure" do
    in_temp_repo(fn ->
      write_template!(@template)

      failed_evidence = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [ ] `make -C elixir all` not run locally because the focused check failed first.
      - [x] `mix test test/mix/tasks/pr_body_check_test.exs` failed locally.
      """

      File.write!("body.md", failed_evidence)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Test Plan must include at least one checked local validation command or targeted check"
    end)
  end

  test "passes when skipped heavy validation is justified with narrower local evidence" do
    in_temp_repo(fn ->
      write_template!(@template)

      justified_skip = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [ ] `make -C elixir all` not run locally because dependency install is unavailable in this workspace.
      - [x] `mix test test/mix/tasks/pr_body_check_test.exs` passed locally as narrower validation.
      """

      File.write!("body.md", justified_skip)

      output =
        capture_io(fn ->
          Check.run(["lint", "--file", "body.md"])
        end)

      assert output =~ "PR body format OK"
    end)
  end

  test "fails when skipped heavy validation reason is only attached to targeted evidence" do
    in_temp_repo(fn ->
      write_template!(@template)

      misplaced_reason = """
      #### Context

      Context text.

      #### TL;DR

      Short summary.

      #### Summary

      - First change.

      #### Alternatives

      - Alternative considered.

      #### Test Plan

      - [ ] `make -C elixir all`
      - [x] `mix test test/mix/tasks/pr_body_check_test.exs` passed locally because it covers the changed code.
      """

      File.write!("body.md", misplaced_reason)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Test Plan must explain why the heavy local validation check was not run"
    end)
  end

  defp in_temp_repo(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "validate-pr-body-task-test-#{unique}")

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

  defp write_template!(content) do
    File.mkdir_p!(".github")
    File.write!(".github/pull_request_template.md", content)
  end
end
