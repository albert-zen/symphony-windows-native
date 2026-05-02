defmodule SymphonyElixir.TestLaneContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)

  test "default test lane excludes true Windows-native tests" do
    assert File.read!(Path.join(@repo_root, "elixir/test/test_helper.exs")) =~
             "exclude: [windows_native: true]"

    assert File.read!(Path.join(@repo_root, "elixir/test/symphony_elixir/windows_lifecycle_scripts_test.exs")) =~
             "@moduletag :windows_native"
  end

  test "windows-native-test lane opts true Windows-native tests back in" do
    makefile = File.read!(Path.join(@repo_root, "elixir/Makefile"))
    make_cmd = File.read!(Path.join(@repo_root, "elixir/make.cmd"))

    assert makefile =~ ~r/windows-native-test:\s*\n\t\$\(MIX\) test --include windows_native .*windows_lifecycle_scripts_test\.exs/

    assert make_cmd =~ ~r/:windows_native_test\s*\r?\n"%MIX_CMD%" test --include windows_native .*windows_lifecycle_scripts_test\.exs/
  end
end
