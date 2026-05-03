defmodule SymphonyElixirWeb.CodexTailServerTest do
  use SymphonyElixir.TestSupport

  alias Phoenix.PubSub
  alias SymphonyElixirWeb.CodexTailServer

  test "start offset prevents replaying already loaded rollout lines" do
    path = rollout_path()
    write_message!(path, "old message")
    {:ok, stat} = File.stat(path)

    rollout_id = "tail-offset-#{System.unique_integer([:positive])}"
    topic = CodexTailServer.topic(rollout_id)
    assert :ok = PubSub.subscribe(SymphonyElixir.PubSub, topic)

    assert {:ok, _pid} =
             CodexTailServer.start(
               rollout_id: rollout_id,
               path: path,
               start_offset: stat.size,
               poll_interval_ms: 10
             )

    refute_receive {:rollout_item, ^rollout_id, %{text: "old message"}}, 80

    write_message!(path, "new message", append: true)

    assert_receive {:rollout_item, ^rollout_id, %{text: "new message"}}, 250
    refute_receive {:rollout_item, ^rollout_id, %{text: "old message"}}, 80
  end

  test "tail server stops after idle timeout when there are no subscribers" do
    path = rollout_path()
    write_message!(path, "hello")
    rollout_id = "tail-idle-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             CodexTailServer.start(
               rollout_id: rollout_id,
               path: path,
               poll_interval_ms: 10,
               idle_timeout_ms: 20
             )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 250
  end

  defp rollout_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-tail-server-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write_message!(path, text, opts \\ []) do
    payload =
      %{
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "type" => "response_item",
        "payload" => %{
          "type" => "message",
          "role" => "assistant",
          "content" => text
        }
      }
      |> Jason.encode!()
      |> Kernel.<>("\n")

    if Keyword.get(opts, :append, false) do
      File.write!(path, payload, [:append])
    else
      File.write!(path, payload)
    end
  end
end
