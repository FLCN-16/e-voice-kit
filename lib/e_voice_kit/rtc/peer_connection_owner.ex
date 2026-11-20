defmodule EVoiceKit.RTC.PeerConnectionOwner do
  @moduledoc """
  Process owner managing an ExWebRTC PeerConnection for one participant.
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
    :session_pid,
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
  Applies a remote SDP offer and generates a corresponding local SDP answer.
  Uses native ExWebRTC when available, or falls back to RFC-compliant SDP synthesis.
  """
  def apply_offer(owner_pid, offer_sdp) when is_binary(offer_sdp) do
    GenServer.call(owner_pid, {:apply_offer, offer_sdp})
  end

  @doc """
  Adds a remote trickle ICE candidate to the PeerConnection.
  """
  def add_ice_candidate(owner_pid, candidate_map) when is_map(candidate_map) do
    GenServer.call(owner_pid, {:add_ice_candidate, candidate_map})
  end

  @doc """
  Transmits an RTP packet outbound to the connected peer.
  Accepts either raw binary RTP packets or `%ExRTP.Packet{}` structs.
  """
  def send_rtp(owner_pid, track_sid, rtp_packet) do
    GenServer.cast(owner_pid, {:send_rtp, track_sid, rtp_packet})
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
    session_pid = Keyword.get(opts, :session_pid)

    # Initialize ExWebRTC PeerConnection if available
    pc = start_peer_connection_if_available(opts)

    state = %__MODULE__{
      pc_id: pc_id,
      participant_sid: participant_sid,
      router_pid: router_pid,
      session_pid: session_pid,
      pc: pc,
      connection_state: :new,
      ice_state: :new
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:apply_offer, offer_sdp}, _from, %{pc: nil} = state) do
    answer_sdp = SDP.generate_audio_answer(offer_sdp)
    new_state = %{state | connection_state: :connected, ice_state: :connected}
    {:reply, {:ok, answer_sdp}, new_state}
  end

  def handle_call({:apply_offer, offer_sdp}, _from, %{pc: pc} = state) do
    result =
      try do
        offer_desc = struct(ExWebRTC.SessionDescription, %{type: :offer, sdp: offer_sdp})

        with :ok <- apply(ExWebRTC.PeerConnection, :set_remote_description, [pc, offer_desc]),
             {:ok, answer} <- apply(ExWebRTC.PeerConnection, :create_answer, [pc]),
             :ok <- apply(ExWebRTC.PeerConnection, :set_local_description, [pc, answer]) do
          {:ok, answer.sdp}
        else
          error ->
            Logger.warning("ExWebRTC SDP negotiation failed: #{inspect(error)}, using fallback answer")
            {:ok, SDP.generate_audio_answer(offer_sdp)}
        end
      rescue
        e ->
          Logger.warning("ExWebRTC error during offer/answer: #{inspect(e)}, using fallback answer")
          {:ok, SDP.generate_audio_answer(offer_sdp)}
      end

    case result do
      {:ok, answer_sdp} ->
        new_state = %{state | connection_state: :connected, ice_state: :connected}
        {:reply, {:ok, answer_sdp}, new_state}

      err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:add_ice_candidate, candidate_map}, _from, %{pc: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:add_ice_candidate, candidate_map}, _from, %{pc: pc} = state) do
    try do
      cand_str = candidate_map["candidate"] || candidate_map[:candidate] || ""
      mid = candidate_map["sdpMid"] || candidate_map[:sdp_mid]
      m_line = candidate_map["sdpMLineIndex"] || candidate_map[:sdp_m_line_index]

      if cand_str != "" and Code.ensure_loaded?(ExWebRTC.ICECandidate) do
        candidate =
          struct(ExWebRTC.ICECandidate, %{
            candidate: cand_str,
            sdp_mid: mid,
            sdp_m_line_index: m_line
          })

        apply(ExWebRTC.PeerConnection, :add_ice_candidate, [pc, candidate])
      end
    rescue
      _ -> :ok
    end

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

  # Outbound media from SFU DownTrack to peer
  @impl true
  def handle_info({:forwarded_rtp, track_sid, packet}, state) do
    if state.pc != nil and function_exported?(ExWebRTC.PeerConnection, :send_rtp, 3) do
      try do
        apply(ExWebRTC.PeerConnection, :send_rtp, [state.pc, track_sid, packet])
      rescue
        _ -> :ok
      end
    end

    new_state = %{state | packets_sent: state.packets_sent + 1}
    {:noreply, new_state}
  end

  # Inbound media from ExWebRTC PeerConnection: supports ExRTP.Packet struct or raw binary
  @impl true
  def handle_info({:ex_webrtc, _pc, {:rtp, track_id, _rid, packet}}, state) do
    new_state = %{state | packets_received: state.packets_received + 1}

    # Route incoming packet into SFU Router if attached
    if is_pid(state.router_pid) do
      Router.forward_packet(state.router_pid, track_id, packet)
    end

    {:noreply, new_state}
  end

  # ExWebRTC trickle ICE candidate discovered locally
  @impl true
  def handle_info({:ex_webrtc, _pc, {:ice_candidate, candidate}}, state) do
    if is_pid(state.session_pid) and is_map(candidate) do
      cand_map = %{
        "candidate" => Map.get(candidate, :candidate, ""),
        "sdpMid" => Map.get(candidate, :sdp_mid, "0"),
        "sdpMLineIndex" => Map.get(candidate, :sdp_m_line_index, 0)
      }

      send(state.session_pid, {:local_ice_candidate, cand_map})
    end

    {:noreply, state}
  end

  # ExWebRTC connection state change
  @impl true
  def handle_info({:ex_webrtc, _pc, {:connection_state_change, connection_state}}, state) do
    {:noreply, %{state | connection_state: connection_state}}
  end

  # ExWebRTC remote track added
  @impl true
  def handle_info({:ex_webrtc, _pc, {:track, track}}, state) do
    track_id = Map.get(track, :id, generate_id("TR_"))
    new_tracks = Map.put(state.tracks, track_id, track)
    {:noreply, %{state | tracks: new_tracks}}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:send_rtp, track_sid, packet}, state) do
    if state.pc != nil and function_exported?(ExWebRTC.PeerConnection, :send_rtp, 3) do
      try do
        apply(ExWebRTC.PeerConnection, :send_rtp, [state.pc, track_sid, packet])
      rescue
        _ -> :ok
      end
    end

    new_state = %{state | packets_sent: state.packets_sent + 1}
    {:noreply, new_state}
  end

  # --- Internal Helpers ---

  defp start_peer_connection_if_available(opts) do
    if Code.ensure_loaded?(ExWebRTC.PeerConnection) and
         function_exported?(ExWebRTC.PeerConnection, :start_link, 1) do
      pc_opts = [
        ice_servers:
          Keyword.get(opts, :ice_servers, [
            %{urls: "stun:stun.l.google.com:19302"}
          ]),
        audio_codecs: [
          %{
            name: "opus",
            clock_rate: 48000,
            channels: 2,
            payload_type: 111
          }
        ]
      ]

      case apply(ExWebRTC.PeerConnection, :start_link, [pc_opts]) do
        {:ok, pc} ->
          if function_exported?(ExWebRTC.PeerConnection, :add_transceiver, 3) do
            apply(ExWebRTC.PeerConnection, :add_transceiver, [pc, :audio, [direction: :sendrecv]])
          end

          pc

        _error ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp generate_id(prefix) do
    prefix <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
