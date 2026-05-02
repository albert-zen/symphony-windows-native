defmodule SymphonyElixir.PathSafetyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PathSafety

  defmodule FakeFile do
    def lstat(path) do
      path = normalize(path)
      link = Process.get({__MODULE__, :link})
      denied = Process.get({__MODULE__, :denied})

      cond do
        path == normalize(link) ->
          {:ok, %File.Stat{type: :symlink}}

        path == normalize(denied) ->
          {:error, :eacces}

        path_is_ancestor?(path, link) or path_is_ancestor?(path, denied) ->
          {:ok, %File.Stat{type: :directory}}

        true ->
          {:error, :enoent}
      end
    end

    defp path_is_ancestor?(_path, nil), do: false

    defp path_is_ancestor?(path, descendant) do
      descendant = normalize(descendant)
      path != descendant and String.starts_with?(descendant, path <> "/")
    end

    defp normalize(nil), do: nil

    defp normalize(path) do
      path
      |> to_string()
      |> String.replace("\\", "/")
      |> String.downcase()
    end
  end

  test "canonicalize returns expanded path when a trailing segment does not exist" do
    root = Path.join(System.tmp_dir!(), "symphony-path-safety-missing-#{System.unique_integer([:positive])}")
    missing = Path.join([root, "existing", "future", "workspace"])

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(root, "existing"))

    assert PathSafety.canonicalize(missing) == {:ok, Path.expand(missing)}
  end

  test "canonicalize returns the filesystem root when there are no path segments" do
    root = System.tmp_dir!() |> Path.expand() |> Path.split() |> hd()

    assert PathSafety.canonicalize(root) == {:ok, root}
  end

  test "canonicalize resolves symlinks before appending remaining segments" do
    root = Path.join(System.tmp_dir!(), "symphony-path-safety-link-#{System.unique_integer([:positive])}")
    target = Path.join(root, "target")
    link = Path.join(root, "link")

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(target, "nested"))

    case File.ln_s(target, link) do
      :ok ->
        assert {:ok, canonical_path} = PathSafety.canonicalize(Path.join([link, "nested", "file.txt"]))

        assert SymphonyElixir.TestSupport.normalize_path_for_assertion(canonical_path) ==
                 SymphonyElixir.TestSupport.normalize_path_for_assertion(Path.join([target, "nested", "file.txt"]))

      {:error, reason} when reason in [:eperm, :eacces, :enotsup] ->
        :ok
    end
  end

  test "canonicalize resolves injected symlink targets portably" do
    root = Path.join(System.tmp_dir!(), "symphony-path-safety-fake-link-#{System.unique_integer([:positive])}")
    link = Path.join(root, "link")
    target = Path.join(root, "target")

    Process.put({FakeFile, :link}, link)

    assert {:ok, canonical_path} =
             PathSafety.canonicalize(Path.join([link, "nested", "file.txt"]),
               file_module: FakeFile,
               read_link_fun: fn path ->
                 assert SymphonyElixir.TestSupport.normalize_path_for_assertion(IO.chardata_to_string(path)) ==
                          SymphonyElixir.TestSupport.normalize_path_for_assertion(link)

                 {:ok, String.to_charlist(target)}
               end
             )

    assert canonical_path == Path.expand(Path.join([target, "nested", "file.txt"]))
  end

  test "canonicalize returns filesystem errors with the expanded path" do
    root = Path.join(System.tmp_dir!(), "symphony-path-safety-denied-#{System.unique_integer([:positive])}")
    denied = Path.join(root, "denied")

    Process.put({FakeFile, :denied}, denied)

    assert PathSafety.canonicalize(Path.join([denied, "workspace"]), file_module: FakeFile) ==
             {:error, {:path_canonicalize_failed, Path.expand(Path.join([denied, "workspace"])), :eacces}}
  end
end
