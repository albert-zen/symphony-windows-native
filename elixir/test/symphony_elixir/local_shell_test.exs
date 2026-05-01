defmodule SymphonyElixir.LocalShellTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.LocalShell

  test "selects a host-native shell command shape" do
    assert {:ok, executable, args} = LocalShell.shell_args("echo ok")

    executable_name =
      executable
      |> Path.basename()
      |> String.downcase()

    if LocalShell.windows?() do
      assert executable_name in ["pwsh.exe", "powershell.exe", "pwsh", "powershell"]
      assert "-Command" in args
      refute "-lc" in args
    else
      assert executable_name in ["sh", "bash"]
      assert ["-lc", "echo ok"] == args
    end
  end

  test "selects a direct Windows port command shape when resolvable" do
    if LocalShell.windows?() do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony local shell path #{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(test_root)
      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_path(previous_path)
        File.rm_rf(test_root)
      end)

      codex_cmd = Path.join(test_root, "codex.cmd")
      codex_script = Path.join([test_root, "node_modules", "@openai", "codex", "bin", "codex.js"])
      File.mkdir_p!(Path.dirname(codex_script))

      File.write!(codex_cmd, """
      @echo off
      SETLOCAL
      SET dp0=%~dp0
      "%_prog%" "%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js" %*
      """)

      File.write!(Path.join(test_root, "codex"), "#!/bin/sh\nexit 99\n")
      File.write!(codex_script, "process.exit(0);\n")
      System.put_env("PATH", test_root <> ";" <> (previous_path || ""))

      case System.find_executable("node") || System.find_executable("node.exe") do
        nil ->
          assert {:error, :windows_node_not_found} = LocalShell.port_args("codex app-server --json")

        node ->
          assert {:ok, executable, args} = LocalShell.port_args("codex app-server --json")

          assert String.downcase(Path.expand(executable)) ==
                   String.downcase(Path.expand(node))

          assert args == [Path.expand(codex_script), "app-server", "--json"]
          refute (Path.basename(executable) |> String.downcase()) in ["cmd.exe", "pwsh.exe", "powershell.exe"]
      end
    else
      assert {:ok, executable, args} = LocalShell.port_args("echo ok")

      assert (executable |> Path.basename() |> String.downcase()) in ["sh", "bash"]
      assert args == ["-lc", "echo ok"]
    end
  end

  test "runs a host-native shell command" do
    command =
      if LocalShell.windows?() do
        "Write-Output ok"
      else
        "printf ok"
      end

    assert {:ok, {output, 0}} = LocalShell.run(command)
    assert String.trim(output) == "ok"
  end

  test "opens a port through a host-native stdio-preserving shell" do
    test_root = Path.join(System.tmp_dir!(), "symphony local shell #{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    command = stdin_echo_command(test_root)

    assert {:ok, port} =
             LocalShell.open_port(command, [
               :binary,
               :exit_status,
               :stderr_to_stdout,
               line: 1024
             ])

    Port.command(port, "ping\n")

    assert_receive {^port, {:data, {:eol, "ping"}}}, 5_000
    Port.close(port)
  end

  defp stdin_echo_command(_test_root) do
    if LocalShell.windows?() do
      erl = System.find_executable("erl.exe") || System.find_executable("erl") || raise "erl executable not found"
      code = "case io:get_line('') of eof -> ok; Line -> io:format(\"~s\", [Line]) end, halt()."

      quote_arg(erl) <> " -noshell -eval " <> quote_arg(code)
    else
      "read line; printf '%s\\n' \"$line\""
    end
  end

  defp quote_arg(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(value), do: System.put_env("PATH", value)
end
