defmodule EVoiceKit.SFU.Router do
  @moduledoc """
  Selective Forwarding Unit (SFU) track router and fast-path packet dispatcher.

  Maintains UpTrack publication and DownTrack subscriber fan-out mappings.
  Forwards RTP packets asynchronously to subscriber sink processes with SSRC/PT remapping.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 16).
  """

  use GenServer
  require Logger

  alias EVoiceKit.SFU.{DownTrack, PacketMapper, UpTrack}

  defstruct [
    up_tracks: %{},
    subscriptions: %{}
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Registers a publisher UpTrack in the router.
  """
  def register_up_track(router, %UpTrack{} = up_track) do
    GenServer.call(router, {:register_up_track, up_track})
  end

  @doc """
  Unregisters an UpTrack and removes all its DownTrack subscriptions.
  """
  def unregister_up_track(router, track_sid) do
    GenServer.call(router, {:unregister_up_track, track_sid})
  end

  @doc """
  Creates a subscriber DownTrack for an UpTrack.
  """
  def subscribe(router, subscriber_sid, track_sid, sink_pid, opts \\ []) do
    GenServer.call(router, {:subscribe, subscriber_sid, track_sid, sink_pid, opts})
  end

  @doc """
  Removes a subscriber DownTrack.
  """
  def unsubscribe(router, subscriber_sid, track_sid) do
    GenServer.call(router, {:unsubscribe, subscriber_sid, track_sid})
  end

  @doc """
  Fast-path packet forwarding: fans out an RTP packet to all active subscribers of the track.
  Dispatches asynchronously without blocking the caller.
  """
  def forward_packet(router, track_sid, rtp_packet_binary) when is_binary(rtp_packet_binary) do
    GenServer.cast(router, {:forward_packet, track_sid, rtp_packet_binary})
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{up_tracks: %{}, subscriptions: %{}}}
  end

  @impl true
  def handle_call({:register_up_track, %UpTrack{track_sid: sid} = track}, _from, state) do
    new_tracks = Map.put(state.up_tracks, sid, track)
    {:reply, :ok, %{state | up_tracks: new_tracks}}
  end

  @impl true
  def handle_call({:unregister_up_track, track_sid}, _from, state) do
    new_tracks = Map.delete(state.up_tracks, track_sid)
    new_subs = Map.delete(state.subscriptions, track_sid)
    {:reply, :ok, %{state | up_tracks: new_tracks, subscriptions: new_subs}}
  end

  @impl true
  def handle_call({:subscribe, subscriber_sid, track_sid, sink_pid, opts}, _from, state) do
    case Map.get(state.up_tracks, track_sid) do
      nil ->
        {:reply, {:error, :track_not_found}, state}

      _up_track ->
        down_track = DownTrack.new(subscriber_sid, track_sid, sink_pid, opts)
        track_subs = Map.get(state.subscriptions, track_sid, %{})
        updated_track_subs = Map.put(track_subs, subscriber_sid, down_track)

        new_subs = Map.put(state.subscriptions, track_sid, updated_track_subs)
        {:reply, {:ok, down_track}, %{state | subscriptions: new_subs}}
    end
  end

  @impl true
  def handle_call({:unsubscribe, subscriber_sid, track_sid}, _from, state) do
    case Map.get(state.subscriptions, track_sid) do
      nil ->
        {:reply, :ok, state}

      track_subs ->
        updated_track_subs = Map.delete(track_subs, subscriber_sid)
        new_subs = Map.put(state.subscriptions, track_sid, updated_track_subs)
        {:reply, :ok, %{state | subscriptions: new_subs}}
    end
  end

  @impl true
  def handle_cast({:forward_packet, track_sid, rtp_binary}, state) do
    case Map.get(state.subscriptions, track_sid) do
      nil ->
        # No subscribers: drop packet safely without buffering
        {:noreply, state}

      subscribers ->
        # Fan-out to all active subscribers asynchronously
        for {_sub_sid, %DownTrack{active: true} = down_track} <- subscribers do
          case PacketMapper.rewrite_for_down_track(rtp_binary, down_track) do
            {:ok, rewritten_rtp} ->
              send(down_track.sink_pid, {:forwarded_rtp, down_track.track_sid, rewritten_rtp})

            _error ->
              :ok
          end
        end

        {:noreply, state}
    end
  end
end
