defmodule SymphonyElixir.Codex.RolloutReaderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.RolloutReader

  @tmp_dir System.tmp_dir!()

  defp write_jsonl!(lines) do
    name = "rollout-test-#{System.unique_integer([:positive])}.jsonl"
    path = Path.join(@tmp_dir, name)
    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")

    on_exit_cleanup(path)
    path
  end

  defp on_exit_cleanup(path) do
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
  end

  describe "read_meta/1" do
    test "parses session_meta from the first line" do
      path =
        write_jsonl!([
          %{
            "timestamp" => "2026-05-02T10:43:37.948Z",
            "type" => "session_meta",
            "payload" => %{
              "id" => "session-abc",
              "cwd" => "d:\\desktop\\symphony-runtime\\workspaces\\ALB-39",
              "originator" => "Codex Desktop",
              "cli_version" => "0.128.0",
              "model_provider" => "openai",
              "timestamp" => "2026-05-02T10:43:30.579Z"
            }
          },
          %{"timestamp" => "2026-05-02T10:43:38Z", "type" => "event_msg", "payload" => %{"type" => "task_started"}}
        ])

      assert {:ok, meta} = RolloutReader.read_meta(path)
      assert meta.session_id == "session-abc"
      assert meta.cwd == "d:\\desktop\\symphony-runtime\\workspaces\\ALB-39"
      assert meta.originator == "Codex Desktop"
      assert %DateTime{} = meta.started_at
    end

    test "returns :empty_file when the file is empty" do
      path = Path.join(@tmp_dir, "rollout-empty-#{System.unique_integer([:positive])}.jsonl")
      File.write!(path, "")
      on_exit_cleanup(path)

      assert {:error, :empty_file} = RolloutReader.read_meta(path)
    end

    test "returns :no_session_meta when the first line is not a session_meta record" do
      path =
        write_jsonl!([
          %{"timestamp" => "2026-05-02T10:43:38Z", "type" => "event_msg", "payload" => %{"type" => "task_started"}}
        ])

      assert {:error, :no_session_meta} = RolloutReader.read_meta(path)
    end

    test "returns :open_failed when the file does not exist" do
      assert {:error, {:open_failed, _}} = RolloutReader.read_meta(Path.join(@tmp_dir, "does-not-exist.jsonl"))
    end
  end

  describe "stream/1 + to_conversation_item/1" do
    test "projects assistant messages, hides developer/system roles, drops meta" do
      path =
        write_jsonl!([
          %{
            "timestamp" => "2026-05-02T10:00:00Z",
            "type" => "session_meta",
            "payload" => %{"id" => "s1", "cwd" => "/tmp/workspaces/ALB-1"}
          },
          %{
            "timestamp" => "2026-05-02T10:00:01Z",
            "type" => "response_item",
            "payload" => %{
              "type" => "message",
              "role" => "developer",
              "content" => [%{"type" => "input_text", "text" => "permissions instructions"}]
            }
          },
          %{
            "timestamp" => "2026-05-02T10:00:02Z",
            "type" => "response_item",
            "payload" => %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "Hello"}]
            }
          },
          %{
            "timestamp" => "2026-05-02T10:00:03Z",
            "type" => "response_item",
            "payload" => %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "Hi"}]
            }
          },
          %{
            "timestamp" => "2026-05-02T10:00:04Z",
            "type" => "event_msg",
            "payload" => %{"type" => "task_completed"}
          },
          %{
            "timestamp" => "2026-05-02T10:00:05Z",
            "type" => "event_msg",
            "payload" => %{"type" => "error", "message" => "boom"}
          }
        ])

      items =
        path
        |> RolloutReader.stream()
        |> Stream.map(&RolloutReader.to_conversation_item/1)
        |> Enum.reject(&is_nil/1)

      kinds = Enum.map(items, & &1.kind)
      assert kinds == [:user_message, :assistant_message, :state_change, :error]

      [_, assistant, _, error] = items
      assert assistant.text == "Hi"
      assert error.text == "boom"
    end

    test "skips malformed JSON lines without crashing" do
      path = Path.join(@tmp_dir, "rollout-bad-#{System.unique_integer([:positive])}.jsonl")
      File.write!(
        path,
        Enum.join(
          [
            Jason.encode!(%{"timestamp" => "x", "type" => "session_meta", "payload" => %{"id" => "s1"}}),
            "{not json",
            Jason.encode!(%{
              "timestamp" => "y",
              "type" => "response_item",
              "payload" => %{
                "type" => "message",
                "role" => "assistant",
                "content" => [%{"type" => "output_text", "text" => "ok"}]
              }
            })
          ],
          "\n"
        ) <> "\n"
      )

      on_exit_cleanup(path)

      items =
        path
        |> RolloutReader.stream()
        |> Stream.map(&RolloutReader.to_conversation_item/1)
        |> Enum.reject(&is_nil/1)

      assert [%{kind: :assistant_message, text: "ok"}] = items
    end

    test "extracts function_call name and reasoning text" do
      assert %{kind: :tool_call, text: "rg"} =
               RolloutReader.to_conversation_item(
                 {:response,
                  %{
                    "timestamp" => "2026-05-02T10:00:00Z",
                    "payload" => %{"type" => "function_call", "name" => "rg", "arguments" => %{"q" => "x"}, "call_id" => "c1"}
                  }}
               )

      assert %{kind: :reasoning, text: "thinking"} =
               RolloutReader.to_conversation_item(
                 {:response,
                  %{
                    "timestamp" => "2026-05-02T10:00:01Z",
                    "payload" => %{"type" => "reasoning", "text" => "thinking"}
                  }}
               )
    end
  end
end
