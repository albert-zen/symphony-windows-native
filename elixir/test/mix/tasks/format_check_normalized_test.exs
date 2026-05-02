defmodule Mix.Tasks.FormatCheckNormalizedTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Error, as: MixError
  alias Mix.Tasks.Format.CheckNormalized

  setup do
    Mix.Task.reenable("format.check_normalized")
    :ok
  end

  test "passes when formatter output differs only by line endings" do
    in_tmp_project(fn ->
      File.write!("sample.exs", "value = :ok\r\n")

      assert capture_io(fn -> CheckNormalized.run([]) end) =~
               "format.check_normalized: all formatter inputs are formatted"
    end)
  end

  test "fails when formatter changes more than line endings" do
    in_tmp_project(fn ->
      File.write!("sample.exs", "value=:ok\r\n")

      assert_raise MixError, ~r/format\.check_normalized failed/, fn ->
        capture_io(:stderr, fn -> CheckNormalized.run([]) end)
      end
    end)
  end

  defp in_tmp_project(fun) do
    root = Path.join(System.tmp_dir!(), "format-check-normalized-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(root)
      File.write!(Path.join(root, ".formatter.exs"), "[inputs: [\"*.exs\"]]\n")
      File.cd!(root, fun)
    after
      File.rm_rf(root)
    end
  end
end
