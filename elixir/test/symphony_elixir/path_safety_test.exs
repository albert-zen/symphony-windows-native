defmodule SymphonyElixir.PathSafetyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PathSafety

  test "canonicalize returns expanded path when a trailing segment does not exist" do
    root = Path.join(System.tmp_dir!(), "symphony-path-safety-missing-#{System.unique_integer([:positive])}")
    missing = Path.join([root, "existing", "future", "workspace"])

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(root, "existing"))

    assert PathSafety.canonicalize(missing) == {:ok, Path.expand(missing)}
  end

  test "canonicalize resolves symlinks before appending remaining segments" do
    root = Path.join(System.tmp_dir!(), "symphony-path-safety-link-#{System.unique_integer([:positive])}")
    target = Path.join(root, "target")
    link = Path.join(root, "link")

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(target, "nested"))

    case File.ln_s(target, link) do
      :ok ->
        assert PathSafety.canonicalize(Path.join([link, "nested", "file.txt"])) ==
                 {:ok, Path.join([target, "nested", "file.txt"])}

      {:error, reason} when reason in [:eperm, :eacces, :enotsup] ->
        :ok
    end
  end
end
