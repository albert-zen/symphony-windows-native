defmodule SymphonyElixir.LogFile do
  @moduledoc """
  Configures OTP's built-in rotating disk log handler for application logs.
  """

  require Logger

  @handler_id :symphony_disk_log
  @default_log_relative_path "log/symphony.log"
  @default_max_bytes 10 * 1024 * 1024
  @default_max_files 5

  @spec default_log_file() :: Path.t()
  def default_log_file do
    default_log_file(File.cwd!())
  end

  @spec default_log_file(Path.t()) :: Path.t()
  def default_log_file(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_log_relative_path)
  end

  @spec configure() :: :ok
  def configure do
    log_file = Application.get_env(:symphony_elixir, :log_file, default_log_file())
    max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes, @default_max_bytes)
    max_files = Application.get_env(:symphony_elixir, :log_file_max_files, @default_max_files)

    setup_disk_handler(log_file, max_bytes, max_files)
  end

  defp setup_disk_handler(log_file, max_bytes, max_files) do
    expanded_path = Path.expand(log_file)
    :ok = File.mkdir_p(Path.dirname(expanded_path))
    :ok = remove_existing_handler()

    case :logger.add_handler(
           @handler_id,
           :logger_disk_log_h,
           disk_log_handler_config(expanded_path, max_bytes, max_files)
         ) do
      :ok ->
        remove_default_console_handler()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to configure rotating log file handler: #{inspect(reason)}")
        :ok
    end
  end

  defp remove_existing_handler do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, {:not_found, @handler_id}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp remove_default_console_handler do
    case :logger.remove_handler(:default) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp disk_log_handler_config(path, max_bytes, max_files) do
    %{
      level: :all,
      formatter:
        {SymphonyElixir.LogFile.Formatter,
         %{
           single_line: true,
           template: [:time, " ", :level, " event_id=", :event_id, " ", :msg, "\n"]
         }},
      config: %{
        file: String.to_charlist(path),
        type: :wrap,
        max_no_bytes: max_bytes,
        max_no_files: max_files
      }
    }
  end
end

defmodule SymphonyElixir.LogFile.Formatter do
  @moduledoc false

  @osc_escape_pattern ~r/\e\].*?(?:\a|\e\\)/
  @ansi_escape_pattern ~r/\e\[[0-?]*[ -\/]*[@-~]/
  @control_pattern ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/
  @carriage_return_pattern ~r/\r(?!\n)/

  @spec format(:logger.log_event(), map()) :: String.t()
  def format(%{meta: metadata} = log_event, config) when is_map(metadata) do
    log_event
    |> put_in([:meta, :event_id], Map.get_lazy(metadata, :event_id, &event_id/0))
    |> :logger_formatter.format(config)
    |> IO.iodata_to_binary()
    |> sanitize()
  end

  @spec sanitize(String.t()) :: String.t()
  def sanitize(value) when is_binary(value) do
    value
    |> String.replace(@osc_escape_pattern, "")
    |> String.replace(@ansi_escape_pattern, "")
    |> String.replace(@carriage_return_pattern, "")
    |> String.replace("\r\n", "\n")
    |> String.replace(@control_pattern, "")
  end

  defp event_id do
    ~c"log-" ++ Integer.to_charlist(System.unique_integer([:positive, :monotonic]))
  end
end
