defmodule SymphonyElixir.TestSupport do
  @moduledoc """
  Shared test helpers.

  Use `write_fake_codex!/3` for app-server protocol fixtures that must run on
  both Windows and Unix. It writes a Node payload behind a Unix-style shim; the
  production `LocalShell` Windows launcher recognizes that shim and executes the
  `.js` file with `node.exe`.

  Direct executable fakes for tools launched with `System.cmd/3` or
  `Port.open/2`, such as `ssh` and `gh`, should be real platform executables.
  Keep Unix shell-script fakes Unix-only when the production code intentionally
  resolves and launches the real host executable directly.
  """

  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, unquote(opts)
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          restore_env: 2,
          stop_default_http_server: 0,
          write_fake_codex!: 2,
          write_fake_codex!: 3,
          write_node_executable!: 2,
          write_workflow_file!: 1,
          write_workflow_file!: 2
        ]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Workflow.clear_workflow_file_path()
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          Application.delete_env(:symphony_elixir, :local_os_pid_alive?)
          Application.delete_env(:symphony_elixir, :linear_client_module)
          Application.delete_env(:symphony_elixir, :task_supervisor_start_child)
          Application.delete_env(:symphony_elixir, :orchestrator_status_fake_linear)
          Application.delete_env(:symphony_elixir, :tasklist_lookup)
          Application.delete_env(:symphony_elixir, :tasklist_cmd)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if path == SymphonyElixir.Workflow.workflow_file_path() do
      SymphonyElixir.Workflow.set_workflow_file_path(path)
    else
      reload_workflow_store()
    end

    :ok
  end

  defp reload_workflow_store do
    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def windows? do
    match?({:win32, _}, :os.type())
  end

  def path_separator, do: if(windows?(), do: ";", else: ":")

  def normalize_path_for_assertion(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> then(fn expanded ->
      if windows?() do
        expanded
        |> String.downcase()
        |> normalize_windows_temp_root_for_assertion()
      else
        expanded
      end
    end)
  end

  defp normalize_windows_temp_root_for_assertion(path) do
    windows_temp_roots_for_assertion()
    |> Enum.reduce(path, fn root, normalized ->
      String.replace(normalized, root, "<windows-temp-root>")
    end)
  end

  defp windows_temp_roots_for_assertion do
    [
      System.tmp_dir!(),
      System.get_env("TEMP"),
      System.get_env("TMP"),
      System.get_env("USERPROFILE") && Path.join(System.get_env("USERPROFILE"), "AppData/Local/Temp")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn path ->
      path
      |> Path.expand()
      |> String.replace("\\", "/")
      |> String.downcase()
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  def write_node_executable!(executable, javascript) when is_binary(executable) and is_binary(javascript) do
    script = executable <> ".js"
    script_name = Path.basename(script)

    File.write!(script, javascript)

    File.write!(executable, """
    #!/bin/sh
    basedir=$(dirname "$(echo "$0" | sed -e 's,\\\\,/,g')")
    exec node "$basedir/#{script_name}" "$@"
    """)

    File.chmod!(executable, 0o755)
    executable
  end

  def write_fake_codex!(executable, steps, opts \\ []) when is_binary(executable) and is_list(steps) do
    trace_env = Keyword.get(opts, :trace_env)
    default_trace = Keyword.get(opts, :default_trace, "/tmp/symphony-fake-codex.trace")
    trace_prefix = Keyword.get(opts, :trace_prefix, "JSON:")
    startup_trace = Keyword.get(opts, :startup_trace, [])
    steps_json = Jason.encode!(Enum.map(steps, &normalize_fake_codex_step/1))
    startup_trace_json = Jason.encode!(Enum.map(List.wrap(startup_trace), &to_string/1))

    write_node_executable!(
      executable,
      """
      const fs = require("fs");
      const readline = require("readline");

      const steps = #{steps_json};
      const traceEnv = #{Jason.encode!(trace_env)};
      const defaultTrace = #{Jason.encode!(default_trace)};
      const tracePrefix = #{Jason.encode!(trace_prefix)};
      const startupTrace = #{startup_trace_json};
      const traceFile = traceEnv ? (process.env[traceEnv] || defaultTrace) : null;
      let count = 0;

      function writeTrace(line) {
        if (traceFile) {
          fs.appendFileSync(traceFile, `${tracePrefix}${line}\\n`);
        }
      }

      function writeStartupTrace() {
        if (!traceFile) {
          return;
        }

        for (const marker of startupTrace) {
          if (marker === "argv") {
            fs.appendFileSync(traceFile, `ARGV:${process.argv.slice(2).join(" ")}\\n`);
          } else if (marker === "cwd") {
            fs.appendFileSync(traceFile, `CWD:${process.cwd()}\\n`);
          } else if (marker === "run") {
            fs.appendFileSync(traceFile, `RUN:${Date.now()}-${process.pid}\\n`);
          } else if (marker === "run_marker") {
            fs.appendFileSync(traceFile, "RUN\\n");
          }
        }
      }

      function writeMany(stream, values) {
        for (const value of values || []) {
          stream.write(`${value}\\n`);
        }
      }

      function replyToInputId(line, payloadKey, payload) {
        const request = JSON.parse(line);
        process.stdout.write(`${JSON.stringify({ id: request.id, [payloadKey]: payload })}\\n`);
      }

      function applyStep(step, line) {
        if (step.reply_result !== null && step.reply_result !== undefined) {
          replyToInputId(line, "result", step.reply_result);
        }

        if (step.reply_error !== null && step.reply_error !== undefined) {
          replyToInputId(line, "error", step.reply_error);
        }

        writeMany(process.stderr, step.stderr);
        writeMany(process.stdout, step.stdout);

        if (step.exit !== null && step.exit !== undefined) {
          process.exit(step.exit);
        }

        if (step.hold) {
          setInterval(() => {}, 1000);
        }
      }

      writeStartupTrace();

      const rl = readline.createInterface({ input: process.stdin, terminal: false });

      rl.on("line", line => {
        count += 1;
        writeTrace(line);
        applyStep(steps[count - 1] || { exit: 0 }, line);
      });
      """
    )
  end

  defp normalize_fake_codex_step(step) when is_binary(step), do: %{stdout: [step]}

  defp normalize_fake_codex_step(step) when is_list(step) do
    step
    |> Map.new()
    |> normalize_fake_codex_step()
  end

  defp normalize_fake_codex_step(step) when is_map(step) do
    step
    |> Map.update(:stdout, [], &List.wrap/1)
    |> Map.update(:stderr, [], &List.wrap/1)
  end

  def symlink_skip_reason do
    if windows?() do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-symlink-probe-#{System.unique_integer([:positive])}"
        )

      try do
        target = Path.join(test_root, "target")
        link = Path.join(test_root, "link")

        File.mkdir_p!(target)

        case File.ln_s(target, link) do
          :ok -> nil
          {:error, reason} -> "Windows symlink privileges unavailable: #{inspect(reason)}"
        end
      after
        File.rm_rf(test_root)
      end
    end
  end

  def stop_default_http_server do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil -> :ok
      supervisor -> stop_default_http_server(supervisor)
    end
  end

  defp stop_default_http_server(supervisor) when is_pid(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find(fn
      {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
      _child -> false
    end)
    |> terminate_default_http_server(supervisor)
  end

  defp terminate_default_http_server({SymphonyElixir.HttpServer, pid, _type, _modules}, supervisor) when is_pid(pid) do
    :ok = Supervisor.terminate_child(supervisor, SymphonyElixir.HttpServer)

    if Process.alive?(pid) do
      Process.exit(pid, :normal)
    end

    :ok
  end

  defp terminate_default_http_server(_child, _supervisor), do: :ok

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_labels: [],
          tracker_dispatch_states: ["Todo"],
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          workspace_startup_cleanup_ttl_ms: 7 * 24 * 60 * 60 * 1_000,
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 30_000,
          codex_stall_timeout_ms: 300_000,
          codex_command_watchdog_long_running_ms: 300_000,
          codex_command_watchdog_idle_ms: 120_000,
          codex_command_watchdog_stalled_ms: 300_000,
          codex_command_watchdog_repeated_output_limit: 20,
          codex_command_watchdog_block_on_stall: false,
          codex_review_readiness_repository: nil,
          codex_review_readiness_required_checks: [],
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_labels = Keyword.get(config, :tracker_labels)
    tracker_dispatch_states = Keyword.get(config, :tracker_dispatch_states)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    workspace_startup_cleanup_ttl_ms = Keyword.get(config, :workspace_startup_cleanup_ttl_ms)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    codex_command_watchdog_long_running_ms = Keyword.get(config, :codex_command_watchdog_long_running_ms)
    codex_command_watchdog_idle_ms = Keyword.get(config, :codex_command_watchdog_idle_ms)
    codex_command_watchdog_stalled_ms = Keyword.get(config, :codex_command_watchdog_stalled_ms)
    codex_command_watchdog_repeated_output_limit = Keyword.get(config, :codex_command_watchdog_repeated_output_limit)
    codex_command_watchdog_block_on_stall = Keyword.get(config, :codex_command_watchdog_block_on_stall)
    codex_review_readiness_repository = Keyword.get(config, :codex_review_readiness_repository)
    codex_review_readiness_required_checks = Keyword.get(config, :codex_review_readiness_required_checks)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  labels: #{yaml_value(tracker_labels)}",
        "  dispatch_states: #{yaml_value(tracker_dispatch_states)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        "  startup_cleanup_ttl_ms: #{yaml_value(workspace_startup_cleanup_ttl_ms)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        "  command_watchdog_long_running_ms: #{yaml_value(codex_command_watchdog_long_running_ms)}",
        "  command_watchdog_idle_ms: #{yaml_value(codex_command_watchdog_idle_ms)}",
        "  command_watchdog_stalled_ms: #{yaml_value(codex_command_watchdog_stalled_ms)}",
        "  command_watchdog_repeated_output_limit: #{yaml_value(codex_command_watchdog_repeated_output_limit)}",
        "  command_watchdog_block_on_stall: #{yaml_value(codex_command_watchdog_block_on_stall)}",
        "  review_readiness_repository: #{yaml_value(codex_review_readiness_repository)}",
        "  review_readiness_required_checks: #{yaml_value(codex_review_readiness_required_checks)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
