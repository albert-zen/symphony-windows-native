defmodule SymphonyElixir.Codex.RolloutReader do
  @moduledoc """
  Pure module for reading Codex rollout JSONL files written by the Codex
  app-server (default location `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).

  Each line is a JSON object of the form `{"timestamp", "type", "payload"}`
  with three known types:

    * `"session_meta"`   — emitted once at the top of the file; `payload.cwd`
                          is the workspace path and `payload.id` is the
                          session id.
    * `"event_msg"`      — protocol-level events like `task_started`,
                          `task_completed`, `error`.
    * `"response_item"`  — message items (`role: user|assistant|developer|
                          system`), tool calls, tool outputs, etc.

  This module is responsible for parsing those lines and projecting them
  into a stable `t:conversation_item/0` shape consumed by the dashboard UI.
  It does not own any process state — readers are streams.
  """

  require Logger

  @type rollout_meta :: %{
          path: Path.t(),
          session_id: String.t() | nil,
          cwd: Path.t() | nil,
          started_at: DateTime.t() | nil,
          model: String.t() | nil,
          originator: String.t() | nil,
          cli_version: String.t() | nil
        }

  @type parsed_line ::
          {:meta, map()}
          | {:event, map()}
          | {:response, map()}
          | :unknown

  @typedoc """
  Normalized chat-style item used by the Worker Details transcript view.

  `kind` values: `:assistant_message`, `:user_message`, `:reasoning`,
  `:tool_call`, `:state_change`, `:error`, `:system_note`.
  """
  @type conversation_item :: %{
          required(:kind) => atom(),
          required(:at) => DateTime.t() | nil,
          required(:text) => String.t(),
          required(:meta) => map()
        }

  @max_text_bytes 8_000

  @doc """
  Parse the first `session_meta` line of a rollout file and return its
  metadata. Returns `{:error, reason}` if the file is missing, unreadable,
  or the first line is not a valid `session_meta` record.
  """
  @spec read_meta(Path.t()) :: {:ok, rollout_meta()} | {:error, atom()}
  def read_meta(path) when is_binary(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          read_meta_from_io(io, path)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:open_failed, reason}}
    end
  end

  @doc """
  Stream parsed lines from a rollout file, oldest-first.

  Malformed lines are logged and skipped. The returned stream emits
  `t:parsed_line/0` values; pair with `to_conversation_item/1` to project
  to the chat shape.
  """
  @spec stream(Path.t()) :: Enumerable.t()
  def stream(path) when is_binary(path) do
    Stream.resource(
      fn -> File.open!(path, [:read, :binary]) end,
      fn io ->
        case IO.binread(io, :line) do
          :eof -> {:halt, io}
          {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
          line when is_binary(line) -> {[line], io}
        end
      end,
      &File.close/1
    )
    |> Stream.map(&decode_line(&1, path))
    |> Stream.reject(&is_nil/1)
  end

  @doc """
  Read projected conversation items from a rollout file.

  Pass `limit: n` to return only the latest `n` projected items. This keeps
  Worker Details initial renders bounded even when a Codex session has a long
  JSONL history.
  """
  @spec conversation_items(Path.t(), keyword()) :: [conversation_item()]
  def conversation_items(path, opts \\ []) when is_binary(path) do
    limit = Keyword.get(opts, :limit, :all)

    path
    |> stream()
    |> Stream.map(&to_conversation_item/1)
    |> Stream.reject(&is_nil/1)
    |> take_latest(limit)
  rescue
    _ -> []
  end

  @doc """
  Project a parsed line to a `t:conversation_item/0`.

  Returns `nil` for items that should be hidden from the human transcript
  view (e.g. developer/system roles, low-signal protocol events). Callers
  should `Enum.reject(&is_nil/1)`.
  """
  @spec to_conversation_item(parsed_line()) :: conversation_item() | nil
  def to_conversation_item({:response, %{"timestamp" => ts, "payload" => payload}}) do
    response_item_to_conversation_item(payload, ts)
  end

  def to_conversation_item({:event, %{"timestamp" => ts, "payload" => payload}}) do
    event_to_conversation_item(payload, ts)
  end

  def to_conversation_item({:meta, _}), do: nil
  def to_conversation_item(:unknown), do: nil
  def to_conversation_item(_), do: nil

  # ---- internals ----------------------------------------------------------

  defp take_latest(stream, :all), do: Enum.to_list(stream)

  defp take_latest(stream, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(stream, -limit)

  defp take_latest(_stream, _limit), do: []

  defp read_meta_from_io(io, path) do
    case IO.binread(io, :line) do
      :eof ->
        {:error, :empty_file}

      {:error, reason} ->
        {:error, {:read_failed, reason}}

      line when is_binary(line) ->
        case decode_line(line, path) do
          {:meta, %{"timestamp" => ts, "payload" => payload}} when is_map(payload) ->
            {:ok, build_meta(path, payload, ts)}

          _ ->
            {:error, :no_session_meta}
        end
    end
  end

  defp decode_line(line, path) do
    trimmed = String.trim(line)

    if trimmed == "" do
      nil
    else
      case Jason.decode(trimmed) do
        {:ok, %{"type" => "session_meta"} = obj} ->
          {:meta, obj}

        {:ok, %{"type" => "event_msg"} = obj} ->
          {:event, obj}

        {:ok, %{"type" => "response_item"} = obj} ->
          {:response, obj}

        {:ok, _other} ->
          :unknown

        {:error, reason} ->
          Logger.debug("rollout_reader: skipping malformed line in #{path}: #{inspect(reason)}")

          nil
      end
    end
  end

  defp build_meta(path, payload, ts) when is_map(payload) do
    %{
      path: path,
      session_id: read_string(payload, "id"),
      cwd: read_string(payload, "cwd"),
      started_at: parse_timestamp(payload["timestamp"] || ts),
      model: extract_model(payload),
      originator: read_string(payload, "originator"),
      cli_version: read_string(payload, "cli_version")
    }
  end

  defp extract_model(payload) do
    cond do
      is_binary(payload["model"]) -> payload["model"]
      is_binary(payload["model_provider"]) -> payload["model_provider"]
      true -> nil
    end
  end

  defp read_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp truncate_text(text) when is_binary(text) do
    if byte_size(text) <= @max_text_bytes do
      text
    else
      :binary.part(text, 0, @max_text_bytes) <> " …[truncated]"
    end
  end

  # response_item dispatch
  defp response_item_to_conversation_item(%{"type" => "message"} = payload, ts) do
    role = payload["role"]
    text = extract_message_text(payload["content"])

    cond do
      role == "assistant" and text != "" ->
        %{
          kind: :assistant_message,
          at: parse_timestamp(ts),
          text: truncate_text(text),
          meta: %{}
        }

      role == "user" and text != "" ->
        %{
          kind: :user_message,
          at: parse_timestamp(ts),
          text: truncate_text(text),
          meta: %{}
        }

      role in ["developer", "system"] ->
        # Hidden by default — UI can choose to surface via "show system" toggle.
        nil

      true ->
        nil
    end
  end

  defp response_item_to_conversation_item(%{"type" => "reasoning"} = payload, ts) do
    text = extract_message_text(payload["content"]) |> default_to(payload["text"])

    if text == "" do
      nil
    else
      %{
        kind: :reasoning,
        at: parse_timestamp(ts),
        text: truncate_text(text),
        meta: %{}
      }
    end
  end

  defp response_item_to_conversation_item(
         %{"type" => "function_call"} = payload,
         ts
       ) do
    %{
      kind: :tool_call,
      at: parse_timestamp(ts),
      text: truncate_text(read_string(payload, "name") || "tool_call"),
      meta: %{
        name: read_string(payload, "name"),
        arguments: payload["arguments"],
        call_id: read_string(payload, "call_id")
      }
    }
  end

  defp response_item_to_conversation_item(
         %{"type" => "function_call_output"} = payload,
         ts
       ) do
    output_text = extract_function_output(payload["output"])

    %{
      kind: :tool_call,
      at: parse_timestamp(ts),
      text: truncate_text(output_text),
      meta: %{
        call_id: read_string(payload, "call_id"),
        is_output: true
      }
    }
  end

  defp response_item_to_conversation_item(_, _), do: nil

  defp event_to_conversation_item(%{"type" => type} = payload, ts)
       when type in ["task_started", "task_completed", "thread_started", "turn_completed"] do
    %{
      kind: :state_change,
      at: parse_timestamp(ts),
      text: type,
      meta: Map.take(payload, ["turn_id", "thread_id"])
    }
  end

  defp event_to_conversation_item(%{"type" => "error"} = payload, ts) do
    %{
      kind: :error,
      at: parse_timestamp(ts),
      text: truncate_text(read_string(payload, "message") || "error"),
      meta: payload
    }
  end

  defp event_to_conversation_item(_, _), do: nil

  defp default_to("", fallback) when is_binary(fallback), do: fallback
  defp default_to(value, _fallback), do: value

  # `content` from response_item.message looks like:
  #   [%{"type" => "input_text"|"output_text", "text" => "..."}]
  defp extract_message_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp extract_message_text(text) when is_binary(text), do: text
  defp extract_message_text(_), do: ""

  defp extract_function_output(%{"content" => content}) when is_list(content),
    do: extract_message_text(content)

  defp extract_function_output(text) when is_binary(text), do: text
  defp extract_function_output(_), do: ""
end
