defmodule EVoiceKit.SFU.Router do
  @moduledoc """
  Selective Forwarding Unit (SFU) track router and fast-path packet dispatcher.

  Maintains UpTrack publication and DownTrack subscriber fan-out mappings.
  Uses an ETS table for lock-free, concurrent route lookups, bypassing the GenServer mailbox
  on the media packet path. Dispatches packets asynchronously with slow-subscriber drop policies.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 16) and `docs/adr/0008-track-forwarder-ownership-and-concurrency.md`.
  """

  use GenServer
  require Logger

  alias EVoiceKit.SFU.{DownTrack, PacketMapper, UpTrack}

  @max_subscriber_queue_len 500

  defstruct [
    :table,
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
  Dispatches asynchronously without blocking the caller. If the router has an ETS table,
  the caller reads subscriptions directly from ETS to avoid mailbox bottlenecks.
  """
  def forward_packet(router_or_table, track_sid, packet) do
    case get_subscriptions(router_or_table, track_sid) do
      {:ok, subs} ->
        dispatch_to_subscribers(subs, packet)

      :fallback_cast ->
        GenServer.cast(router_or_table, {:forward_packet, track_sid, packet})
    end
  end

  @doc """
  Returns all active DownTrack subscriptions for an UpTrack.
  """
  def get_subscriptions(router_pid) when is_pid(router_pid) do
    GenServer.call(router_pid, :get_all_subscriptions)
  end

  def get_subscriptions(table, track_sid) when is_reference(table) do
    case :ets.lookup(table, track_sid) do
      [{^track_sid, subs}] -> {:ok, subs}
      [] -> {:ok, %{}}
    end
  rescue
    _ -> :fallback_cast
  end

  def get_subscriptions(router_pid, track_sid) when is_pid(router_pid) do
    try do
      case GenServer.call(router_pid, {:get_subscriptions, track_sid}, 50) do
        {:ok, subs} -> {:ok, subs}
        _ -> :fallback_cast
      end
    catch
      :exit, _ -> :fallback_cast
    end
  end

  def get_subscriptions(_other, _track_sid), do: :fallback_cast

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(:sfu_router_routes, [:set, :public, read_concurrency: true])
    {:ok, %__MODULE__{table: table, up_tracks: %{}, subscriptions: %{}}}
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
    if state.table, do: :ets.delete(state.table, track_sid)
    {:reply, :ok, %{state | up_tracks: new_tracks, subscriptions: new_subs}}
  end

  @impl true
  def handle_call({:subscribe, subscriber_sid, track_sid, sink_pid, opts}, _from, state) do
    dest_ssrc = Keyword.get(opts, :destination_ssrc, :rand.uniform(4_000_000_000))
    dest_pt = Keyword.get(opts, :destination_pt, 111)

    down_track = %DownTrack{
      subscriber_sid: subscriber_sid,
      track_sid: track_sid,
      sink_pid: sink_pid,
      destination_ssrc: dest_ssrc,
      destination_pt: dest_pt,
      seq_offset: Keyword.get(opts, :seq_offset, 0),
      ts_offset: Keyword.get(opts, :ts_offset, 0),
      active: true
    }

    current_track_subs = Map.get(state.subscriptions, track_sid, %{})
    updated_track_subs = Map.put(current_track_subs, subscriber_sid, down_track)
    new_subs = Map.put(state.subscriptions, track_sid, updated_track_subs)

    if state.table, do: :ets.insert(state.table, {track_sid, updated_track_subs})

    {:reply, {:ok, down_track}, %{state | subscriptions: new_subs}}
  end

  @impl true
  def handle_call({:unsubscribe, subscriber_sid, track_sid}, _from, state) do
    case Map.get(state.subscriptions, track_sid) do
      nil ->
        {:reply, :ok, state}

      subs ->
        updated_track_subs = Map.delete(subs, subscriber_sid)
        new_subs = Map.put(state.subscriptions, track_sid, updated_track_subs)
        if state.table, do: :ets.insert(state.table, {track_sid, updated_track_subs})
        {:reply, :ok, %{state | subscriptions: new_subs}}
    end
  end

  @impl true
  def handle_call({:get_subscriptions, track_sid}, _from, state) do
    subs = Map.get(state.subscriptions, track_sid, %{})
    {:reply, {:ok, subs}, state}
  end

  @impl true
  def handle_call(:get_all_subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  @impl true
  def handle_cast({:forward_packet, track_sid, packet}, state) do
    case Map.get(state.subscriptions, track_sid) do
      nil ->
        {:noreply, state}

      subs ->
        dispatch_to_subscribers(subs, packet)
        {:noreply, state}
    end
  end

  # --- Internal Helpers ---

  defp dispatch_to_subscribers(subs, packet) when is_map(subs) do
    for {_sub_sid, down_track} <- subs do
      if down_track.active and is_pid(down_track.sink_pid) do
        # Check subscriber queue depth to isolate slow subscribers
        case Process.info(down_track.sink_pid, :message_queue_len) do
          {:message_queue_len, len} when len > @max_subscriber_queue_len ->
            # Drop packet for slow subscriber to avoid unbounded memory buffer
            :dropped_slow_subscriber

          _ ->
            remapped = PacketMapper.remap_packet(packet, down_track)
            send(down_track.sink_pid, {:forwarded_rtp, down_track.track_sid, remapped})
        end
      end
    end
  end

  defp dispatch_to_subscribers(_, _), do: :ok

  defp generate_id(prefix) do
    prefix <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
