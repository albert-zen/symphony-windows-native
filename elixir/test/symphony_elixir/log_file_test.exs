defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.LogFile
  alias SymphonyElixir.LogFile.Formatter

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/symphony.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/symphony-logs") == "/tmp/symphony-logs/log/symphony.log"
  end

  test "file logger formatter emits plain single-line audit events" do
    event = %{
      level: :info,
      msg:
        {:string,
         "SYMPHONY STATUS " <>
           IO.ANSI.red() <> "red" <> IO.ANSI.reset() <> <<27>> <> "]0;title\a" <> <<0>>},
      meta: %{time: 1_771_000_000_000_000}
    }

    line =
      Formatter.format(event, %{
        single_line: true,
        template: [:time, " ", :level, " event_id=", :event_id, " ", :msg, "\n"]
      })

    assert line =~ " info event_id=log-"
    assert line =~ "SYMPHONY STATUS red"
    refute line =~ IO.ANSI.red()
    refute line =~ IO.ANSI.reset()
    refute line =~ "title"
    refute line =~ <<0>>
  end

  test "file logger formatter removes carriage-return redraw artifacts" do
    event = %{
      level: :info,
      msg: {:string, "progress 10%\rprogress 20%\rprogress complete"},
      meta: %{time: 1_771_000_000_000_000, event_id: ~c"event-123"}
    }

    line =
      Formatter.format(event, %{
        single_line: true,
        template: [:time, " ", :level, " event_id=", :event_id, " ", :msg, "\n"]
      })

    assert line =~ " info event_id=event-123 progress 10%progress 20%progress complete\n"
    refute line =~ "\r"
    assert String.ends_with?(line, "\n")
  end

  test "file logger formatter emits unicode duration units as valid UTF-8" do
    event = %{
      level: :debug,
      msg: {"Replied in ~B~ts", [409, ~c"µs"]},
      meta: %{time: 1_771_000_000_000_000, event_id: ~c"event-456"}
    }

    line =
      Formatter.format(event, %{
        single_line: true,
        template: [:time, " ", :level, " event_id=", :event_id, " ", :msg, "\n"]
      })

    assert line =~ " debug event_id=event-456 Replied in 409µs\n"
    assert String.valid?(line)
  end

  test "file logger handler writes unicode duration units without formatter errors" do
    path = Path.join(System.tmp_dir!(), "symphony-log-file-#{System.unique_integer([:positive])}.log")
    handler_id = :"symphony_log_file_test_#{System.unique_integer([:positive])}"
    primary_level = :logger.get_primary_config() |> Map.fetch!(:level)

    :ok =
      :logger.add_handler(handler_id, :logger_std_h, %{
        level: :debug,
        formatter:
          {Formatter,
           %{
             single_line: true,
             template: [:time, " ", :level, " event_id=", :event_id, " ", :msg, "\n"]
           }},
        config: %{type: {:file, String.to_charlist(path)}}
      })

    try do
      :ok = :logger.set_primary_config(:level, :debug)
      :logger.log(:debug, {"Replied in ~B~ts", [409, ~c"µs"]}, %{})
      :ok = :logger.remove_handler(handler_id)

      log = File.read!(path)

      assert log =~ "Replied in 409µs"
      assert String.valid?(log)
      refute log =~ "FORMATTER ERROR"
    after
      :logger.remove_handler(handler_id)
      :logger.set_primary_config(:level, primary_level)
      File.rm(path)
    end
  end
end
