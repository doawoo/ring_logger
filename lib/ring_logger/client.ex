defmodule RingLogger.Client do
  use GenServer

  @moduledoc """
  Interact with the RingLogger
  """

  alias RingLogger.Server

  defmodule State do
    @moduledoc false
    defstruct io: nil,
              colors: nil,
              metadata: nil,
              format: nil,
              level: nil,
              index: 0,
              module_levels: %{}
  end

  @doc """
  Start up a client GenServer. Except for just getting the contents of the ring buffer, you'll
  need to create one of these. See `configure/2` for information on options.
  """
  def start_link(config \\ []) do
    GenServer.start_link(__MODULE__, config)
  end

  @doc """
  Stop a client.
  """
  def stop(client_pid) do
    GenServer.stop(client_pid)
  end

  @doc """
  Update the client configuration.

  Options include:
  * `:io` - Defaults to `:stdio`
  * `:colors` -
  * `:metadata` - A KV list of additional metadata
  * `:format` - A custom format string, or a {module, function} tuple (see
    https://hexdocs.pm/logger/master/Logger.html#module-custom-formatting)
  * `:level` - The minimum log level to report.
  """
  @spec configure(GenServer.server(), [RingLogger.client_option()]) :: :ok
  def configure(client_pid, config) do
    GenServer.call(client_pid, {:config, config})
  end

  @doc """
  Attach the current IEx session to the logger. It will start printing log messages.
  """
  @spec attach(GenServer.server()) :: :ok
  def attach(client_pid) do
    GenServer.call(client_pid, :attach)
  end

  @doc """
  Detach the current IEx session from the logger.
  """
  @spec detach(GenServer.server()) :: :ok
  def detach(client_pid) do
    GenServer.call(client_pid, :detach)
  end

  @doc """
  Get the last n messages.
  """
  @spec tail(GenServer.server(), non_neg_integer()) :: :ok
  def tail(client_pid, n) do
    GenServer.call(client_pid, {:tail, n})
  end

  @doc """
  Get the next set of the messages in the log.
  """
  @spec next(GenServer.server()) :: :ok
  def next(client_pid) do
    GenServer.call(client_pid, :next)
  end

  @doc """
  Reset the index into the log for `tail/1` to the oldest entry.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(client_pid) do
    GenServer.call(client_pid, :reset)
  end

  @doc """
  Helper method for formatting log messages per the current client's
  configuration.
  """
  @spec format(GenServer.server(), RingLogger.entry()) :: :ok
  def format(client_pid, message) do
    GenServer.call(client_pid, {:format, message})
  end

  @doc """
  Run a regular expression on each entry in the log and print out the matchers.
  """
  @spec grep(GenServer.server(), Regex.t()) :: :ok
  def grep(client_pid, regex) do
    GenServer.call(client_pid, {:grep, regex})
  end

  def init(config) do
    state = %State{
      io: Keyword.get(config, :io, :stdio),
      colors: configure_colors(config),
      metadata: Keyword.get(config, :metadata, []) |> configure_metadata(),
      format: Keyword.get(config, :format) |> configure_formatter(),
      level: Keyword.get(config, :level, :debug),
      module_levels: Keyword.get(config, :module_levels, %{})
    }

    {:ok, state}
  end

  def handle_info({:log, msg}, state) do
    maybe_print(msg, state)
    {:noreply, state}
  end

  def handle_call({:config, config}, _from, state) do
    new_config = Keyword.drop(config, [:index])
    {:reply, :ok, struct(state, new_config)}
  end

  def handle_call(:attach, _from, state) do
    {:reply, Server.attach_client(self()), state}
  end

  def handle_call(:detach, _from, state) do
    {:reply, Server.detach_client(self()), state}
  end

  def handle_call(:next, _from, state) do
    messages = Server.get(state.index)

    case List.last(messages) do
      nil ->
        # No messages
        {:reply, :ok, state}

      last_message ->
        Enum.each(messages, fn msg -> maybe_print(msg, state) end)
        next_index = message_index(last_message) + 1
        {:reply, :ok, %{state | index: next_index}}
    end
  end

  def handle_call({:tail, n}, _from, state) do
    Enum.each(Server.tail(n), fn msg -> maybe_print(msg, state) end)

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | index: 0}}
  end

  def handle_call({:grep, regex}, _from, state) do
    Server.get()
    |> Enum.each(fn msg -> maybe_print(msg, regex, state) end)

    {:reply, :ok, state}
  end

  def handle_call({:format, msg}, _from, state) do
    item = format_message(msg, state)
    {:reply, item, state}
  end

  defp message_index({_level, {_, _msg, _ts, md}}), do: Keyword.get(md, :index)

  defp format_message({level, {_, msg, ts, md}}, state) do
    metadata = take_metadata(md, state.metadata)

    state.format
    |> apply_format(level, msg, ts, metadata)
    |> color_event(level, state.colors, md)
  end

  ## Helpers

  defp apply_format({mod, fun}, level, msg, ts, metadata) do
    apply(mod, fun, [level, msg, ts, metadata])
  end

  defp apply_format(format, level, msg, ts, metadata) do
    Logger.Formatter.format(format, level, msg, ts, metadata)
  end

  defp configure_metadata(:all), do: :all
  defp configure_metadata(metadata), do: Enum.reverse(metadata)

  defp configure_colors(config) do
    colors = Keyword.get(config, :colors, [])

    %{
      debug: Keyword.get(colors, :debug, :cyan),
      info: Keyword.get(colors, :info, :normal),
      warn: Keyword.get(colors, :warn, :yellow),
      error: Keyword.get(colors, :error, :red),
      enabled: Keyword.get(colors, :enabled, IO.ANSI.enabled?())
    }
  end

  defp meet_level?(_lvl, nil), do: true
  defp meet_level?(_lvl, :none), do: false

  defp meet_level?(lvl, min) do
    Logger.compare_levels(lvl, min) != :lt
  end

  defp take_metadata(metadata, :all), do: metadata

  defp take_metadata(metadata, keys) do
    Enum.reduce(keys, [], fn key, acc ->
      case Keyword.fetch(metadata, key) do
        {:ok, val} -> [{key, val} | acc]
        :error -> acc
      end
    end)
  end

  defp color_event(data, _level, %{enabled: false}, _md), do: data

  defp color_event(data, level, %{enabled: true} = colors, md) do
    color = md[:ansi_color] || Map.fetch!(colors, level)
    [IO.ANSI.format_fragment(color, true), data | IO.ANSI.reset()]
  end

  defp configure_formatter({mod, fun}), do: {mod, fun}

  defp configure_formatter(format) do
    Logger.Formatter.compile(format)
  end

  defp maybe_print(msg, state) do
    if should_print?(msg, state) do
      item = format_message(msg, state)
      IO.binwrite(state.io, item)
    end
  end

  defp maybe_print({_, {_, text, _, _}} = msg, r, state) do
    flattened_text = IO.iodata_to_binary(text)

    if should_print?(msg, state) && Regex.match?(r, flattened_text) do
      item = format_message(msg, state)
      IO.binwrite(state.io, item)
    end
  end

  defp get_module_from_msg({_, {_, _, _, meta}}) do
    Keyword.get(meta, :module)
  end

  defp should_print?({level, _} = msg, %State{module_levels: module_levels} = state) do
    module = get_module_from_msg(msg)

    with module_level when not is_nil(module_level) <- Map.get(module_levels, module),
         true <- meet_level?(level, module_level) do
      true
    else
      nil ->
        meet_level?(level, state.level)

      _ ->
        false
    end
  end
end
