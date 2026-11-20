defmodule EVoiceKit.DataChannels.Relay do
  @moduledoc """
  WebRTC DataChannel application message routing and flow control.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 20).
  """

  use GenServer
  require Logger

  @default_max_message_size 64 * 1024

  defstruct [
    :room_id,
    participants: %{},
    max_message_size: @default_max_message_size
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Registers a participant's DataChannel sink pid.
  """
  def register_sink(relay, participant_sid, sink_pid) do
    GenServer.call(relay, {:register_sink, participant_sid, sink_pid})
  end

  @doc """
  Unregisters a participant's sink.
  """
  def unregister_sink(relay, participant_sid) do
    GenServer.call(relay, {:unregister_sink, participant_sid})
  end

  @doc """
  Dispatches an application data packet either to a specific participant or broadcast to the room.
  """
  def dispatch(relay, sender_sid, target, packet_binary) when is_binary(packet_binary) do
    GenServer.cast(relay, {:dispatch, sender_sid, target, packet_binary})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    room_id = Keyword.get(opts, :room_id, "default")
    max_size = Keyword.get(opts, :max_message_size, @default_max_message_size)

    {:ok, %__MODULE__{room_id: room_id, max_message_size: max_size, participants: %{}}}
  end

  @impl true
  def handle_call({:register_sink, participant_sid, sink_pid}, _from, state) do
    new_participants = Map.put(state.participants, participant_sid, sink_pid)
    {:reply, :ok, %{state | participants: new_participants}}
  end

  @impl true
  def handle_call({:unregister_sink, participant_sid}, _from, state) do
    new_participants = Map.delete(state.participants, participant_sid)
    {:reply, :ok, %{state | participants: new_participants}}
  end

  @impl true
  def handle_cast({:dispatch, sender_sid, :all, packet_binary}, state) do
    if byte_size(packet_binary) <= state.max_message_size do
      for {sid, sink_pid} <- state.participants, sid != sender_sid do
        send(sink_pid, {:data_channel_message, sender_sid, packet_binary})
      end
    else
      Logger.warning("DataChannel packet from #{sender_sid} exceeded maximum message size")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:dispatch, sender_sid, target_sid, packet_binary}, state) do
    if byte_size(packet_binary) <= state.max_message_size do
      case Map.get(state.participants, target_sid) do
        nil -> :ok
        sink_pid -> send(sink_pid, {:data_channel_message, sender_sid, packet_binary})
      end
    end

    {:noreply, state}
  end
end
