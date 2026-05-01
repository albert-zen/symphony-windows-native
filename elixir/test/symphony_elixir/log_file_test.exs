defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: true

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
end
