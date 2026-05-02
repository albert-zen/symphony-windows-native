defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  @spec canonicalize(Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path, opts \\ []) when is_binary(path) do
    file_module = Keyword.get(opts, :file_module, File)
    read_link_fun = Keyword.get(opts, :read_link_fun, &:file.read_link_all/1)
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments, file_module, read_link_fun) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(root, resolved_segments, [], _file_module, _read_link_fun),
    do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest], file_module, read_link_fun) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case file_module.lstat(candidate_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- read_link_fun.(String.to_charlist(candidate_path)) do
          resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
          {target_root, target_segments} = split_absolute_path(resolved_target)
          resolve_segments(target_root, [], target_segments ++ rest, file_module, read_link_fun)
        end

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest, file_module, read_link_fun)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end
end
