defmodule EVoiceKit.SIP.RoomAdapter do
  @moduledoc """
  Bridges external SIP / PSTN call legs into E-Voice-Kit room sessions.
  Adapts telephony G.711 PCMU/PCMA media and translates RTP streams to/from the SFU Router.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 23).
  """

  use GenServer
  require Logger

  alias EVoiceKit.SFU.{Router, UpTrack}

  defstruct [
    :call_id,
    :room_name,
    :router_pid,
    :sip_socket,
    :remote_ip,
    :remote_port,
    :published_track_sid,
    codec: :pcmu,
    sequence_number: 0,
    timestamp: 0,
    ssrc: 12345
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Attaches the SIP call leg to a room and registers its published audio track.
  """
  def attach_room(adapter, room_name, router_pid) do
    GenServer.call(adapter, {:attach_room, room_name, router_pid})
  end

  @doc """
  Receives an incoming UDP RTP packet from the SIP carrier and forwards into the room.
  """
  def handle_inbound_sip_rtp(adapter, rtp_binary) when is_binary(rtp_binary) do
    GenServer.cast(adapter, {:inbound_sip_rtp, rtp_binary})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    call_id = Keyword.get(opts, :call_id, "sip_" <> generate_id())
    codec = Keyword.get(opts, :codec, :pcmu)

    state = %__MODULE__{
      call_id: call_id,
      codec: codec,
      ssrc: :crypto.rand_uniform(10_000, 999_999)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:attach_room, room_name, router_pid}, _from, state) do
    track_sid = "TR_SIP_" <> generate_id()
    up_track = UpTrack.new(track_sid, state.call_id, kind: :audio, codec: state.codec, clock_rate: 8000, payload_type: 0)

    if is_pid(router_pid) do
      Router.register_up_track(router_pid, up_track)
    end

    new_state = %{
      state
      | room_name: room_name,
        router_pid: router_pid,
        published_track_sid: track_sid
    }

    Logger.info("SIP leg #{state.call_id} attached to room #{room_name}")
    {:reply, {:ok, track_sid}, new_state}
  end

  @impl true
  def handle_cast({:inbound_sip_rtp, rtp_binary}, state) do
    if is_pid(state.router_pid) and is_binary(state.published_track_sid) do
      Router.forward_packet(state.router_pid, state.published_track_sid, rtp_binary)
    end

    {:noreply, state}
  end

  # Outbound media forwarded from the room to be delivered to the SIP caller
  @impl true
  def handle_info({:forwarded_rtp, _track_sid, rtp_packet}, state) do
    # In production with an active UDP socket:
    # :gen_udp.send(state.sip_socket, state.remote_ip, state.remote_port, rtp_packet)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end
end
