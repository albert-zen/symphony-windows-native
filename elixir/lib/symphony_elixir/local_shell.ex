defmodule SymphonyElixir.LocalShell do
  @moduledoc """
  Host-local shell launcher.

  Local workers run on the orchestrator host, so shell selection needs to match
  that host instead of assuming a Unix userland. Remote SSH workers still use
  the SSH module's Unix shell contract.
  """

  @type run_result :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}

  @spec windows?() :: boolean()
  def windows? do
    match?({:win32, _}, :os.type())
  end

  @spec run(String.t(), keyword()) :: run_result()
  def run(command, opts \\ []) when is_binary(command) and is_list(opts) do
    with {:ok, executable, args} <- shell_args(command) do
      cmd_opts =
        opts
        |> Keyword.take([:cd, :env, :stderr_to_stdout])
        |> Keyword.put_new(:stderr_to_stdout, true)

      {:ok, System.cmd(executable, args, cmd_opts)}
    end
  end

  @spec open_port(String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def open_port(command, opts \\ []) when is_binary(command) and is_list(opts) do
    with {:ok, executable, args} <- port_args(command, opts) do
      port_opts = opts ++ [args: Enum.map(args, &String.to_charlist/1)]

      {:ok, Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)}
    end
  end

  @spec shell_args(String.t()) :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def shell_args(command) when is_binary(command) do
    if windows?() do
      windows_shell_args(command)
    else
      unix_shell_args(command)
    end
  end

  @doc false
  @spec port_args(String.t(), keyword()) :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def port_args(command, opts \\ []) when is_binary(command) and is_list(opts) do
    if windows?() do
      windows_port_args(command, opts)
    else
      unix_shell_args(command)
    end
  end

  defp windows_port_args(command, opts) do
    with {:ok, [program | args]} <- split_command(command),
         {:ok, executable} <- resolve_windows_port_executable(program, port_cwd(opts)) do
      windows_port_executable_args(executable, args)
    else
      {:ok, []} -> {:error, :empty_windows_port_command}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_windows_port_executable(program, cwd) do
    cond do
      String.trim(program) == "" ->
        {:error, :empty_windows_port_command}

      path_command?(program) ->
        resolve_windows_path_command(program, cwd)

      true ->
        resolve_windows_bare_command(program, cwd)
    end
  end

  defp resolve_windows_bare_command(program, cwd) do
    program
    |> windows_path_search_candidates(cwd)
    |> Enum.find(&File.regular?/1)
    |> case do
      nil ->
        {:error, {:windows_port_executable_not_found, program}}

      executable ->
        {:ok, executable}
    end
  end

  defp resolve_windows_path_command(program, cwd) do
    base_path =
      if Path.type(program) == :relative do
        Path.expand(program, cwd || File.cwd!())
      else
        Path.expand(program)
      end

    base_path
    |> windows_path_candidates(:explicit)
    |> Enum.find(&File.regular?/1)
    |> case do
      nil -> {:error, {:windows_port_executable_not_found, program}}
      executable -> {:ok, executable}
    end
  end

  defp windows_port_executable_args(executable, args) do
    case executable |> Path.extname() |> String.downcase() do
      extension when extension in [".bat", ".cmd"] ->
        windows_node_shim_args(executable, args)

      "" ->
        windows_shebang_args(executable, args)

      _extension ->
        {:ok, executable, args}
    end
  end

  defp windows_node_shim_args(executable, args) do
    with {:ok, script} <- windows_node_shim_script(executable),
         {:ok, node} <- windows_node_executable(Path.dirname(executable)) do
      {:ok, node, [script | args]}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp windows_shebang_args(executable, args) do
    case windows_shebang_line(executable) do
      {:ok, "#!" <> shebang} ->
        cond do
          String.contains?(shebang, "node") ->
            with {:ok, node} <- windows_node_executable(Path.dirname(executable)) do
              {:ok, node, [executable | args]}
            end

          String.contains?(shebang, "sh") or String.contains?(shebang, "bash") ->
            with {:ok, shell} <- windows_unix_shell_executable() do
              {:ok, shell, [executable | args]}
            end

          true ->
            {:error, {:unsupported_windows_port_command, executable}}
        end

      _ ->
        {:ok, executable, args}
    end
  end

  defp windows_shebang_line(executable) do
    case File.open(executable, [:read]) do
      {:ok, file} ->
        line = IO.read(file, :line)
        File.close(file)

        case line && String.trim_leading(line) do
          "#!" <> _ = shebang -> {:ok, String.trim_trailing(shebang)}
          _ -> :error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp windows_shell_args(command) do
    case find_executable(["pwsh", "powershell"]) do
      nil ->
        {:error, :windows_shell_not_found}

      executable ->
        {:ok, executable,
         [
           "-NoLogo",
           "-NoProfile",
           "-NonInteractive",
           "-ExecutionPolicy",
           "Bypass",
           "-Command",
           command
         ]}
    end
  end

  defp unix_shell_args(command) do
    case find_executable(["sh", "bash"]) do
      nil -> {:error, :unix_shell_not_found}
      executable -> {:ok, executable, ["-lc", command]}
    end
  end

  defp windows_unix_shell_executable do
    case find_executable(["sh", "bash"]) || windows_git_shell() do
      nil -> {:error, :windows_unix_shell_not_found}
      executable -> {:ok, executable}
    end
  end

  defp windows_git_shell do
    [
      "C:/Program Files/Git/bin/sh.exe",
      "C:/Program Files/Git/usr/bin/bash.exe",
      "C:/Program Files/Git/bin/bash.exe"
    ]
    |> Enum.find(&File.regular?/1)
  end

  defp find_executable(names) when is_list(names) do
    Enum.find_value(names, &System.find_executable/1)
  end

  defp path_command?(program) do
    Path.type(program) == :absolute or String.contains?(program, ["/", "\\"])
  end

  defp port_cwd(opts) do
    Enum.find_value(opts, fn
      {:cd, cwd} when is_binary(cwd) -> cwd
      {:cd, cwd} when is_list(cwd) -> to_string(cwd)
      _ -> nil
    end)
  end

  defp windows_path_search_candidates(program, cwd) do
    path_dirs =
      "PATH"
      |> System.get_env("")
      |> String.split(";", trim: true)

    cwd_dirs = if is_binary(cwd), do: [cwd], else: []

    (cwd_dirs ++ path_dirs)
    |> Enum.flat_map(&windows_path_candidates(Path.join(&1, program), :path_search))
  end

  defp windows_path_candidates(path, mode) do
    if Path.extname(path) == "" do
      extension_candidates = Enum.map(windows_path_extensions(), &(path <> &1))

      case mode do
        :path_search -> extension_candidates ++ [path]
        :explicit -> [path | extension_candidates]
      end
    else
      [path]
    end
  end

  defp windows_path_extensions do
    "PATHEXT"
    |> System.get_env(".COM;.EXE;.BAT;.CMD")
    |> String.split(";", trim: true)
  end

  defp windows_node_shim_script(executable) do
    with {:ok, content} <- File.read(executable),
         {:ok, relative_script} <- windows_node_shim_relative_script(content) do
      script =
        executable
        |> Path.dirname()
        |> Path.join(relative_script)
        |> Path.expand()

      if File.regular?(script) do
        {:ok, script}
      else
        {:error, {:windows_node_shim_script_not_found, executable, script}}
      end
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, {:unsupported_windows_port_command, executable}}
    end
  end

  defp windows_node_shim_relative_script(content) do
    cond do
      match = Regex.run(~r/"%dp0%\\([^"]+?\.js)"/i, content) ->
        {:ok, match |> List.last() |> String.replace("\\", "/")}

      match = Regex.run(~r/"\$basedir\/([^"]+?\.js)"/, content) ->
        {:ok, List.last(match)}

      match = Regex.run(~r/"\$basedir\\([^"]+?\.js)"/, content) ->
        {:ok, match |> List.last() |> String.replace("\\", "/")}

      true ->
        :error
    end
  end

  defp windows_node_executable(base_dir) do
    local_node = Path.join(base_dir, "node.exe")

    cond do
      File.regular?(local_node) ->
        {:ok, local_node}

      node = System.find_executable("node") ->
        {:ok, node}

      node = System.find_executable("node.exe") ->
        {:ok, node}

      true ->
        {:error, :windows_node_not_found}
    end
  end

  defp split_command(command) do
    command
    |> String.to_charlist()
    |> split_command([], [], :plain, false)
  end

  defp split_command([], token, args, :plain, token_started) do
    {:ok, token |> flush_token(args, token_started) |> Enum.reverse()}
  end

  defp split_command([], _token, _args, {:quote, _quote}, _token_started) do
    {:error, :unterminated_windows_port_quote}
  end

  defp split_command([char | rest], token, args, :plain, token_started)
       when char in [?\s, ?\t, ?\r, ?\n] do
    split_command(rest, [], flush_token(token, args, token_started), :plain, false)
  end

  defp split_command([quote | rest], token, args, :plain, _token_started)
       when quote in [?\", ?'] do
    split_command(rest, token, args, {:quote, quote}, true)
  end

  defp split_command([char | rest], token, args, :plain, _token_started) do
    split_command(rest, [char | token], args, :plain, true)
  end

  defp split_command([?\\, quote | rest], token, args, {:quote, quote}, _token_started) do
    split_command(rest, [quote | token], args, {:quote, quote}, true)
  end

  defp split_command([quote | rest], token, args, {:quote, quote}, _token_started) do
    split_command(rest, token, args, :plain, true)
  end

  defp split_command([char | rest], token, args, {:quote, quote}, _token_started) do
    split_command(rest, [char | token], args, {:quote, quote}, true)
  end

  defp flush_token(token, args, true) do
    [token |> Enum.reverse() |> to_string() | args]
  end

  defp flush_token(_token, args, false), do: args
end
