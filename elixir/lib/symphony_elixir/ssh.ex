defmodule SymphonyElixir.SSH do
  @moduledoc false

  @spec run(String.t(), String.t(), keyword()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      {executable, args} = executable_and_args(executable, ssh_args(host, command))
      {:ok, System.cmd(executable, args, opts)}
    end
  end

  @spec start_port(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start_port(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      line_bytes = Keyword.get(opts, :line)
      {executable, args} = executable_and_args(executable, ssh_args(host, command))

      port_opts =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(args, &String.to_charlist/1)
        ]
        |> maybe_put_line_option(line_bytes)

      {:ok, Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)}
    end
  end

  @spec remote_shell_command(String.t()) :: String.t()
  def remote_shell_command(command) when is_binary(command) do
    "bash -lc " <> shell_escape(command)
  end

  defp ssh_executable do
    case windows_extensionless_executable("ssh") || System.find_executable("ssh") do
      nil -> {:error, :ssh_not_found}
      executable -> {:ok, executable}
    end
  end

  defp executable_and_args(executable, args) do
    case windows_shebang_shell(executable) do
      nil -> {executable, args}
      shell -> {shell, [executable | args]}
    end
  end

  defp windows_extensionless_executable(name) do
    if windows?() do
      "PATH"
      |> System.get_env("")
      |> String.split(";", trim: true)
      |> Enum.map(&Path.join(&1, name))
      |> Enum.find(&File.regular?/1)
    end
  end

  defp windows_shebang_shell(executable) do
    with true <- windows?(),
         {:ok, "#!" <> shebang} <- first_line(executable),
         true <- String.contains?(shebang, ["sh", "bash"]) do
      System.find_executable("sh") || System.find_executable("bash") || windows_git_shell()
    else
      _ -> nil
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  defp windows_git_shell do
    [
      "C:/Program Files/Git/bin/sh.exe",
      "C:/Program Files/Git/usr/bin/bash.exe",
      "C:/Program Files/Git/bin/bash.exe"
    ]
    |> Enum.find(&File.regular?/1)
  end

  defp first_line(path) do
    case File.open(path, [:read]) do
      {:ok, file} ->
        line = IO.read(file, :line)
        File.close(file)

        case line do
          line when is_binary(line) -> {:ok, line |> String.trim_leading() |> String.trim_trailing()}
          _ -> :error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ssh_args(host, command) do
    %{destination: destination, port: port} = parse_target(host)

    []
    |> maybe_put_config()
    |> Kernel.++(["-T"])
    |> maybe_put_port(port)
    |> Kernel.++([destination, remote_shell_command(command)])
  end

  defp maybe_put_line_option(port_opts, nil), do: port_opts
  defp maybe_put_line_option(port_opts, line_bytes), do: Keyword.put(port_opts, :line, line_bytes)

  defp maybe_put_config(args) do
    case System.get_env("SYMPHONY_SSH_CONFIG") do
      config_path when is_binary(config_path) and config_path != "" ->
        args ++ ["-F", config_path]

      _ ->
        args
    end
  end

  defp maybe_put_port(args, nil), do: args
  defp maybe_put_port(args, port), do: args ++ ["-p", port]

  defp parse_target(target) when is_binary(target) do
    trimmed_target = String.trim(target)

    # OpenSSH does not interpret bare "host:port" as "host + port"; it treats the
    # whole value as a hostname and leaves the port at 22. We split that shorthand
    # here so worker config can use "localhost:2222" without requiring ssh:// URIs.
    case Regex.run(~r/^(.*):(\d+)$/, trimmed_target, capture: :all_but_first) do
      [destination, port] ->
        if valid_port_destination?(destination) do
          %{destination: destination, port: port}
        else
          %{destination: trimmed_target, port: nil}
        end

      _ ->
        %{destination: trimmed_target, port: nil}
    end
  end

  defp valid_port_destination?(destination) when is_binary(destination) do
    destination != "" and
      (not String.contains?(destination, ":") or bracketed_host?(destination))
  end

  defp bracketed_host?(destination) when is_binary(destination) do
    # IPv6 literals contain ":" already, so we only accept additional ":port"
    # parsing when the host is explicitly bracketed, e.g. "[::1]:2222".
    String.contains?(destination, "[") and String.contains?(destination, "]")
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
