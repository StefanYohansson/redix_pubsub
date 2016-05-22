defmodule Redix.PubSub.Connection do
  @moduledoc false

  use Connection

  alias Redix.Protocol
  alias Redix.Utils

  require Logger

  defstruct [
    # The options passed when initializing this GenServer
    opts: nil,

    # The TCP socket connected to the Redis server
    socket: nil,

    # The parsing continuation returned by Redix.Protocol if a response is incomplete
    continuation: nil,

    # The current backoff interval
    backoff_current: nil,

    # A dictionary of `channel => recipient_pids` where `channel` is either
    # `{:channel, "foo"}` or `{:pattern, "foo*"}` and `recipient_pids` is an
    # HashDict of pids of recipients to their monitor ref for that
    # channel/pattern.
    subscriptions: HashDict.new,
  ]

  @backoff_exponent 1.5

  ## Callbacks

  def init(opts) do
    state = %__MODULE__{opts: opts}

    if opts[:sync_connect] do
      sync_connect(state)
    else
      {:connect, :init, state}
    end
  end

  def connect(info, state) do
    case Utils.connect(state.opts) do
      {:ok, socket} ->
        state = %{state | socket: socket}
        if info == :backoff do
          Logger.info ["Reconnected to Redis (", Utils.format_host(state), ?)]
          case resubscribe_after_reconnection(state) do
            :ok ->
              {:ok, state}
            {:error, _reason} = error ->
              {:disconnect, error, state}
          end
        else
          {:ok, state}
        end
      {:error, reason} ->
        Logger.error [
          "Failed to connect to Redis (", Utils.format_host(state), "): ",
          Utils.format_error(reason),
        ]

        next_backoff = calc_next_backoff(state.backoff_current || state.opts[:backoff_initial], state.opts[:backoff_max])
        {:backoff, next_backoff, %{state | backoff_current: next_backoff}}
      {:stop, reason} ->
        {:stop, reason, state}
    end
  end

  def disconnect(:stop, state) do
    # TODO: do stuff

    {:stop, :normal, state}
  end

  def disconnect({:error, reason}, state) do
    Logger.error [
      "Disconnected from Redis (", Utils.format_host(state), "): ", Utils.format_error(reason),
    ]

    :ok = :gen_tcp.close(state.socket)

    for {_target, subscribers} <- state.subscriptions, {subscriber, _monitor} <- subscribers do
      send(subscriber, message(:disconnected, %{reason: reason}))
    end

    state = %{state | socket: nil, continuation: nil, backoff_current: state.opts[:backoff_initial]}
    {:backoff, state.opts[:backoff_initial], state}
  end

  def handle_cast({operation, targets, subscriber}, state) when operation in [:subscribe, :psubscribe] do
    register_subscription(state, operation, targets, subscriber)
  end

  def handle_cast({operation, channels, subscriber}, state) when operation in [:unsubscribe, :punsubscribe] do
    register_unsubscription(state, operation, channels, subscriber)
  end

  def handle_cast(:stop, state) do
    {:disconnect, :stop, state}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: :once)
    state = new_data(state, data)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    {:disconnect, {:error, :tcp_closed}, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    {:disconnect, {:error, reason}, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{subscriptions: subscriptions} = state) do
    {targets_to_unsubscribe_from, subscriptions} =
      Enum.flat_map_reduce(subscriptions, subscriptions, fn({key, subscribers}, acc) ->
        subscribers =
          case HashDict.pop(subscribers, pid) do
            {^ref, new_subscribers} -> new_subscribers
            {_, subscribers} -> subscribers
          end
        acc = HashDict.put(acc, key, subscribers)
        if HashDict.size(subscribers) == 0 do
          {[key], HashDict.delete(acc, key)}
        else
          {[], acc}
        end
      end)

    state = %{state | subscriptions: subscriptions}

    if targets_to_unsubscribe_from == [] do
      {:noreply, state}
    else
      {channels, patterns} = Enum.partition(targets_to_unsubscribe_from, &match?({:channel, _}, &1))
      commands = [
        Protocol.pack(["UNSUBSCRIBE" | Enum.map(channels, fn({:channel, channel}) -> channel end)]),
        Protocol.pack(["PUNSUBSCRIBE" | Enum.map(patterns, fn({:pattern, pattern}) -> pattern end)]),
      ]
      send_noreply_or_disconnect(state, commands)
    end
  end

  ## Helper functions

  defp sync_connect(state) do
    case Utils.connect(state.opts) do
      {:ok, socket} ->
        {:ok, %{state | socket: socket}}
      {:error, reason} ->
        {:stop, reason}
      {:stop, _reason} = stop ->
        stop
    end
  end

  defp new_data(state, <<>>) do
    state
  end

  defp new_data(state, data) do
    case (state.continuation || &Protocol.parse/1).(data) do
      {:ok, resp, rest} ->
        state = handle_pubsub_msg(state, resp)
        new_data(%{state | continuation: nil}, rest)
      {:continuation, continuation} ->
        %{state | continuation: continuation}
    end
  end

  defp register_subscription(%{subscriptions: subscriptions} = state, kind, targets, subscriber) do
    msg_kind =
      case kind do
        :subscribe -> :subscribed
        :psubscribe -> :psubscribed
      end

    {targets_to_subscribe_to, subscriptions} =
      Enum.flat_map_reduce(targets, subscriptions, fn(target, acc) ->
        key = key_for_target(kind, target)
        {targets_to_subscribe_to, for_target} =
          if for_target = HashDict.get(acc, key) do
            {[], for_target}
          else
            {[target], HashDict.new()}
          end
        for_target = put_new_lazy(for_target, subscriber, fn -> Process.monitor(subscriber) end)
        acc = HashDict.put(acc, key, for_target)
        send(subscriber, message(msg_kind, %{to: target}))
        {targets_to_subscribe_to, acc}
      end)

    state = %{state | subscriptions: subscriptions}

    if targets_to_subscribe_to == [] do
      {:noreply, state}
    else
      redis_command =
        case kind do
          :subscribe -> "SUBSCRIBE"
          :psubscribe -> "PSUBSCRIBE"
        end

      command = Protocol.pack([redis_command | targets_to_subscribe_to])
      send_noreply_or_disconnect(state, command)
    end
  end

  defp register_unsubscription(%{subscriptions: subscriptions} = state, kind, targets, subscriber) do
    msg_kind =
      case kind do
        :unsubscribe -> :unsubscribed
        :punsubscribe -> :punsubscribed
      end

    {targets_to_unsubscribe_from, subscriptions} =
      Enum.flat_map_reduce(targets, subscriptions, fn(target, acc) ->
        send(subscriber, message(msg_kind, %{from: target}))
        if for_target = HashDict.get(acc, key_for_target(kind, target)) do
          case HashDict.pop(for_target, subscriber) do
            {ref, new_for_target} when is_reference(ref) ->
              Process.demonitor(ref)
              flush_monitor_messages(ref)
              targets_to_unsubscribe_from =
                if HashDict.size(new_for_target) == 0 do
                  [target]
                else
                  []
                end
              acc = HashDict.put(acc, key_for_target(kind, target), new_for_target)
              {targets_to_unsubscribe_from, acc}
            {nil, _} ->
              {[], state}
          end
        else
          {[], state}
        end
      end)

    state = %{state | subscriptions: subscriptions}

    if targets_to_unsubscribe_from == [] do
      {:noreply, state}
    else
      redis_command =
        case kind do
          :unsubscribe -> "UNSUBSCRIBE"
          :punsubscribe -> "PUNSUBSCRIBE"
        end

      command = Protocol.pack([redis_command | targets_to_unsubscribe_from])
      send_noreply_or_disconnect(state, command)
    end
  end

  defp handle_pubsub_msg(state, [operation, _target, _count])
      when operation in ~w(subscribe psubscribe unsubscribe punsubscribe) do
    state
  end

  defp handle_pubsub_msg(%{subscriptions: subscriptions} = state, ["message", channel, payload]) do
    message = message(:message, %{channel: channel, payload: payload})

    subscriptions
    |> HashDict.fetch!({:channel, channel})
    |> Enum.each(fn({subscriber, _monitor}) -> send(subscriber, message) end)

    state
  end

  defp handle_pubsub_msg(%{subscriptions: subscriptions} = state, ["pmessage", pattern, channel, payload]) do
    message = message(:pmessage, %{channel: channel, pattern: pattern, payload: payload})

    subscriptions
    |> HashDict.fetch!({:pattern, pattern})
    |> Enum.each(fn({subscriber, _monitor}) -> send(subscriber, message) end)

    state
  end

  defp calc_next_backoff(backoff_current, backoff_max) do
    next_exponential_backoff = round(backoff_current * @backoff_exponent)

    if backoff_max == :infinity do
      next_exponential_backoff
    else
      min(next_exponential_backoff, backoff_max)
    end
  end

  defp put_new_lazy(hash_dict, key, fun) when is_function(fun, 0) do
    if HashDict.has_key?(hash_dict, key) do
      hash_dict
    else
      HashDict.put(hash_dict, key, fun.())
    end
  end

  defp key_for_target(kind, target) when kind in [:subscribe, :unsubscribe],
    do: {:channel, target}
  defp key_for_target(kind, target) when kind in [:psubscribe, :punsubscribe],
    do: {:pattern, target}

  defp message(kind, meta) when is_atom(kind) and is_map(meta) do
    {:redix_pubsub, self(), kind, meta}
  end

  defp send_noreply_or_disconnect(%{socket: socket} = state, data) do
    case :gen_tcp.send(socket, data) do
      :ok ->
        {:noreply, state}
      {:error, _reason} = error ->
        {:disconnect, error, state}
    end
  end

  defp resubscribe_after_reconnection(%{subscriptions: subscriptions} = state) do
    Enum.each(subscriptions, fn({{kind, target}, subscribers}) ->
      msg_kind =
        case kind do
          :channel -> :subscribed
          :pattern -> :psubscribed
        end
      subscribers
      |> HashDict.keys()
      |> Enum.each(fn(pid) -> send(pid, message(msg_kind, %{to: target})) end)
    end)

    {channels, patterns} = Enum.partition(subscriptions, &match?({{:channel, _}, _}, &1))
    channels = Enum.map(channels, fn({{:channel, channel}, _}) -> channel end)
    patterns = Enum.map(patterns, fn({{:pattern, pattern}, _}) -> pattern end)

    redis_command = []

    redis_command =
      if channels != [] do
        redis_command ++ [["SUBSCRIBE" | channels]]
      else
        redis_command
      end

    redis_command =
      if patterns != [] do
        redis_command ++ [["PSUBSCRIBE" | patterns]]
      else
        redis_command
      end

    if redis_command == [] do
      :ok
    else
      :gen_tcp.send(state.socket, Enum.map(redis_command, &Protocol.pack/1))
    end
  end

  defp flush_monitor_messages(ref) do
    receive do
      {:DOWN, ^ref, _, _, _} -> flush_monitor_messages(ref)
    after
      0 -> :ok
    end
  end
end