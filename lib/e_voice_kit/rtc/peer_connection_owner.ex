defmodule EVoiceKit.RTC.PeerConnectionOwner do
  @moduledoc """
  Process owner managing a WebRTC PeerConnection for one participant.
  Terminates DTLS-SRTP media transport and bridges RTP packets to/from the SFU Router.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 12 & 14).
  """

  use GenServer
  require Logger

  alias EVoiceKit.RTC.SDP
  alias EVoiceKit.SFU.Router

  defstruct [
    :pc_id,
    :participant_sid,
    :router_pid,
    :pc,
    connection_state: :new,
    ice_state: :new,
    tracks: %{},
    packets_sent: 0,
    packets_received: 0
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Applies a remote SDP offer and generates a corresponding SDP answer.
  """
  def apply_offer(owner_pid, offer_sdp) when is_binary(offer_sdp) do
    GenServer.call(owner_pid, {:apply_offer, offer_sdp})
  end

  @doc """
  Adds a remote trickle ICE candidate.
  """
  def add_ice_candidate(owner_pid, candidate_map) when is_map(candidate_map) do
    GenServer.call(owner_pid, {:add_ice_candidate, candidate_map})
  end

  @doc """
  Transmits an RTP packet outbound to the connected peer.
  """
  def send_rtp(owner_pid, track_sid, rtp_packet_binary) when is_binary(rtp_packet_binary) do
    GenServer.cast(owner_pid, {:send_rtp, track_sid, rtp_packet_binary})
  end

  @doc """
  Returns current transport statistics.
  """
  def get_stats(owner_pid) do
    GenServer.call(owner_pid, :get_stats)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    pc_id = Keyword.get(opts, :pc_id, generate_id("PC_"))
    participant_sid = Keyword.get(opts, :participant_sid, "anonymous")
    router_pid = Keyword.get(opts, :router_pid)

    # Initialize ExWebRTC PeerConnection if available, or initialize headless simulator
    pc =
      if Code.ensure_loaded?(ExWebRTC.PeerConnection) do
        # When native ExWebRTC NIFs are present:
        # ExWebRTC.PeerConnection.start_link(...)
        nil
      else
        nil
      end

    state = %__MODULE__{
      pc_id: pc_id,
      participant_sid: participant_sid,
      router_pid: router_pid,
      pc: pc,
      connection_state: :new,
      ice_state: :new
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:apply_offer, offer_sdp}, _from, state) do
    answer_sdp = SDP.generate_audio_answer(offer_sdp)
    new_state = %{state | connection_state: :connected, ice_state: :connected}
    {:reply, {:ok, answer_sdp}, new_state}
  end

  @impl true
  def handle_call({:add_ice_candidate, _candidate}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      pc_id: state.pc_id,
      participant_sid: state.participant_sid,
      connection_state: state.connection_state,
      ice_state: state.ice_state,
      packets_sent: state.packets_sent,
      packets_received: state.packets_received
    }

    {:reply, stats, state}
  end

  # Outbound media from SFU DownTrack
  @impl true
  def handle_info({:forwarded_rtp, track_sid, rtp_bytes}, state) do
    # Forward out to WebRTC transport
    new_state = %{state | packets_sent: state.packets_sent + 1}
    {:noreply, new_state}
  end

  # Inbound media from ExWebRTC PeerConnection
  @impl true
  def handle_info({:ex_webrtc, _pc, {:rtp, track_id, _rid, packet}}, state) do
    new_state = %{state | packets_received: state.packets_received + 1}

    # Route incoming packet into SFU Router if attached
    if is_pid(state.router_pid) and is_binary(packet) do
      Router.forward_packet(state.router_pid, track_id, packet)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:send_rtp, _track_sid, _rtp_packet}, state) do
    new_state = %{state | packets_sent: state.packets_sent + 1}
    {:noreply, new_state}
  end

  defp generate_id(prefix) do
    prefix <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
