defmodule SymphonyElixir.SSHTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SSH

  @fake_ssh_skip if(SymphonyElixir.TestSupport.windows?(),
                   do: "Fake ssh tests use a Unix executable script; Windows coverage for remote SSH uses real ssh.exe.",
                   else: nil
                 )

  if @fake_ssh_skip, do: @tag(skip: @fake_ssh_skip)

  test "run/3 keeps bracketed IPv6 host:port targets intact" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@[::1]:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@[::1]"
    assert trace =~ "bash -lc"
    assert trace =~ "printf ok"
  end

  if @fake_ssh_skip, do: @tag(skip: @fake_ssh_skip)

  test "run/3 leaves unbracketed IPv6-style targets unchanged" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-raw-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("::1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T ::1:2200"
    assert trace =~ "bash -lc"
    refute trace =~ "-p 2200"
  end

  if @fake_ssh_skip, do: @tag(skip: @fake_ssh_skip)

  test "run/3 passes host:port targets through ssh -p" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)
    System.put_env("SYMPHONY_SSH_CONFIG", "/tmp/symphony-test-ssh-config")

    assert {:ok, {"", 0}} =
             SSH.run("localhost:2222", "echo ready", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-F /tmp/symphony-test-ssh-config"
    assert trace =~ "-T -p 2222 localhost"
    assert trace =~ "bash -lc"
    assert trace =~ "echo ready"
  end

  if @fake_ssh_skip, do: @tag(skip: @fake_ssh_skip)

  test "run/3 keeps the user prefix when parsing user@host:port targets" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-user-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@127.0.0.1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@127.0.0.1"
    assert trace =~ "bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 returns an error when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)

    assert {:error, :ssh_not_found} = SSH.run("localhost", "printf ok")
  end

  test "run/3 wraps cmd shims through cmd.exe when ssh.cmd is the available executable" do
    if windows?() do
      :ok
    else
      test_root = Path.join(System.tmp_dir!(), "symphony-ssh-cmd-shim-test-#{System.unique_integer([:positive])}")
      trace_file = Path.join(test_root, "ssh.trace")
      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
        File.rm_rf(test_root)
      end)

      fake_bin_dir = Path.join(test_root, "bin")
      File.mkdir_p!(fake_bin_dir)

      fake_ssh = Path.join(fake_bin_dir, "ssh.cmd")
      fake_cmd = Path.join(fake_bin_dir, "cmd.exe")

      File.write!(fake_ssh, "")

      File.write!(fake_cmd, """
      #!/bin/sh
      printf 'CMD:%s\\n' "$*" >> "#{trace_file}"
      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)
      File.chmod!(fake_cmd, 0o755)
      System.put_env("PATH", fake_bin_dir)

      assert {:ok, {"", 0}} =
               SSH.run("localhost:2222", "printf ok", stderr_to_stdout: true)

      trace = File.read!(trace_file)
      assert trace =~ "/c"
      assert trace =~ "ssh.cmd"
      assert trace =~ "-T -p 2222 localhost"
      assert trace =~ "bash -lc"
    end
  end

  if @fake_ssh_skip, do: @tag(skip: @fake_ssh_skip)

  test "start_port/3 supports binary output without line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    System.delete_env("SYMPHONY_SSH_CONFIG")

    assert {:ok, port} = SSH.start_port("localhost", "printf ok")
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T localhost"
    assert trace =~ "bash -lc"
    refute trace =~ " -F "
  end

  if @fake_ssh_skip, do: @tag(skip: @fake_ssh_skip)

  test "start_port/3 supports line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-line-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    assert {:ok, port} = SSH.start_port("localhost:2222", "printf ok", line: 256)
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2222 localhost"
    assert trace =~ "bash -lc"
  end

  test "remote_shell_command/1 escapes embedded single quotes" do
    assert SSH.remote_shell_command("printf 'hello'") ==
             "bash -lc 'printf '\"'\"'hello'\"'\"''"
  end

  defp install_fake_ssh!(test_root, trace_file, script \\ nil) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, if(windows?(), do: "ssh.cmd", else: "ssh"))

    File.mkdir_p!(fake_bin_dir)

    File.write!(fake_ssh, fake_ssh_script(trace_file, script))

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> SymphonyElixir.TestSupport.path_separator() <> (System.get_env("PATH") || ""))
  end

  defp fake_ssh_script(trace_file, nil) do
    if windows?() do
      """
      @echo off
      echo ARGV:%*>>"#{trace_file}"
      exit /b 0
      """
    else
      """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
      exit 0
      """
    end
  end

  defp fake_ssh_script(trace_file, script) do
    if windows?() do
      """
      @echo off
      echo ARGV:%*>>"#{trace_file}"
      echo ready
      exit /b 0
      """
    else
      script
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  defp wait_for_trace!(trace_file, attempts \\ 20)
  defp wait_for_trace!(trace_file, 0), do: flunk("timed out waiting for fake ssh trace at #{trace_file}")

  defp wait_for_trace!(trace_file, attempts) do
    if File.exists?(trace_file) and File.read!(trace_file) != "" do
      :ok
    else
      Process.sleep(25)
      wait_for_trace!(trace_file, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
