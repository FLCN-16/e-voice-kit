defmodule EVoiceKit.RTC.PeerConnectionOwner do
  @moduledoc """
  Owns one ExWebRTC PeerConnection and maps transport track IDs to application track SIDs.
  """

  use GenServer
  require Logger

  alias EVoiceKit.SFU.Router

  defstruct [
    :pc_id,
    :participant_sid,
    :router_pid,
    :route_table,
    :session_pid,
    :pc,
    connection_state: :new,
    ice_state: :new,
    tracks: %{},
    inbound_track_ids: %{},
    pending_track_sids: [],
    outgoing_track_ids: [],
    packets_sent: 0,
    packets_received: 0
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def apply_offer(owner_pid, offer_sdp) when is_binary(offer_sdp),
    do: GenServer.call(owner_pid, {:apply_offer, offer_sdp})

  def add_ice_candidate(owner_pid, candidate_map) when is_map(candidate_map),
    do: GenServer.call(owner_pid, {:add_ice_candidate, candidate_map})

  def bind_published_track(owner_pid, track_sid) when is_binary(track_sid),
    do: GenServer.call(owner_pid, {:bind_published_track, track_sid})

  def send_rtp(owner_pid, track_sid, rtp_packet),
    do: GenServer.cast(owner_pid, {:send_rtp, track_sid, rtp_packet})

  def get_stats(owner_pid), do: GenServer.call(owner_pid, :get_stats)

  @impl true
  def init(opts) do
    router_pid = Keyword.get(opts, :router_pid)
    route_table = if is_pid(router_pid), do: Router.route_table(router_pid), else: nil
    {pc, outgoing_track_ids} = start_peer_connection_if_available(opts)

    if is_nil(pc) or outgoing_track_ids == [] do
      if is_pid(pc), do: apply(ExWebRTC.PeerConnection, :stop, [pc])
      {:stop, :peer_connection_or_sender_unavailable}
    else
      {:ok,
       %__MODULE__{
         pc_id: Keyword.get(opts, :pc_id, generate_id("PC_")),
         participant_sid: Keyword.get(opts, :participant_sid, "anonymous"),
         router_pid: router_pid,
         route_table: route_table,
         session_pid: Keyword.get(opts, :session_pid),
         pc: pc,
         outgoing_track_ids: outgoing_track_ids
       }}
    end
  end

  @impl true
  def handle_call({:bind_published_track, track_sid}, _from, state) do
    unbound =
      state.tracks
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(state.inbound_track_ids, &1))

    case unbound do
      [track_id | _] ->
        {:reply, :ok, %{state | inbound_track_ids: Map.put(state.inbound_track_ids, track_id, track_sid)}}

      [] ->
        {:reply, :ok, %{state | pending_track_sids: state.pending_track_sids ++ [track_sid]}}
    end
  end

  @impl true
  def handle_call({:apply_offer, _offer_sdp}, _from, %{pc: nil} = state),
    do: {:reply, {:error, :peer_connection_unavailable}, state}

  def handle_call({:apply_offer, offer_sdp}, _from, %{pc: pc} = state) do
    result =
      try do
        offer_desc = struct(ExWebRTC.SessionDescription, %{type: :offer, sdp: offer_sdp})

        with :ok <- apply(ExWebRTC.PeerConnection, :set_remote_description, [pc, offer_desc]),
             {:ok, answer} <- apply(ExWebRTC.PeerConnection, :create_answer, [pc]),
             :ok <- apply(ExWebRTC.PeerConnection, :set_local_description, [pc, answer]) do
          {:ok, answer.sdp}
        end
      rescue
        error -> {:error, {:sdp_negotiation_exception, error}}
      end

    case result do
      {:ok, answer_sdp} -> {:reply, {:ok, answer_sdp}, state}
      {:error, reason} ->
        Logger.warning("ExWebRTC SDP negotiation failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:add_ice_candidate, _candidate}, _from, %{pc: nil} = state),
    do: {:reply, {:error, :peer_connection_unavailable}, state}

  def handle_call({:add_ice_candidate, candidate_map}, _from, %{pc: pc} = state) do
    result =
      try do
        candidate_string = candidate_map["candidate"] || candidate_map[:candidate] || ""
        if candidate_string == "" do
          {:error, :empty_ice_candidate}
        else
          candidate =
            struct(ExWebRTC.ICECandidate, %{
              candidate: candidate_string,
              sdp_mid: candidate_map["sdpMid"] || candidate_map[:sdp_mid],
              sdp_m_line_index: candidate_map["sdpMLineIndex"] || candidate_map[:sdp_m_line_index]
            })

          apply(ExWebRTC.PeerConnection, :add_ice_candidate, [pc, candidate])
        end
      rescue
        error -> {:error, {:ice_candidate_failed, error}}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply,
     %{
       pc_id: state.pc_id,
       participant_sid: state.participant_sid,
       connection_state: state.connection_state,
       ice_state: state.ice_state,
       packets_sent: state.packets_sent,
       packets_received: state.packets_received
     }, state}
  end

  @impl true
  def handle_info({:forwarded_rtp, _app_track_sid, packet}, %{pc: pc} = state) when not is_nil(pc) do
    case state.outgoing_track_ids do
      [sender_track_id | _] ->
        if function_exported?(ExWebRTC.PeerConnection, :send_rtp, 3) do
          apply(ExWebRTC.PeerConnection, :send_rtp, [pc, sender_track_id, packet])
          {:noreply, %{state | packets_sent: state.packets_sent + 1}}
        else
          {:noreply, state}
        end

      [] ->
        Logger.warning("Dropping forwarded RTP: no negotiated outgoing sender track")
        {:noreply, state}
    end
  end

  def handle_info({:forwarded_rtp, _track_sid, _packet}, state), do: {:noreply, state}

  @impl true
  def handle_info({:ex_webrtc, _pc, {:rtp, track_id, _rid, packet}}, state) do
    case Map.fetch(state.inbound_track_ids, track_id) do
      {:ok, app_track_sid} ->
        if is_reference(state.route_table) do
          Router.forward_packet(state.route_table, app_track_sid, packet)
        end

        {:noreply, %{state | packets_received: state.packets_received + 1}}

      :error ->
        {:noreply, state}
    end
  end

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

  @impl true
  def handle_info({:ex_webrtc, _pc, {:connection_state_change, connection_state}}, state),
    do: {:noreply, %{state | connection_state: connection_state}}

  @impl true
  def handle_info({:ex_webrtc, _pc, {:track, track}}, state) do
    track_id = Map.get(track, :id)

    if is_nil(track_id) do
      {:noreply, state}
    else
      updated_tracks = Map.put(state.tracks, track_id, track)

      case state.pending_track_sids do
        [track_sid | rest] ->
          {:noreply,
           %{state |
             tracks: updated_tracks,
             inbound_track_ids: Map.put(state.inbound_track_ids, track_id, track_sid),
             pending_track_sids: rest}}

        [] ->
          {:noreply, %{state | tracks: updated_tracks}}
      end
    end
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:send_rtp, _track_sid, packet}, state) do
    case state.outgoing_track_ids do
      [sender_track_id | _] when not is_nil(state.pc) ->
        apply(ExWebRTC.PeerConnection, :send_rtp, [state.pc, sender_track_id, packet])
        {:noreply, %{state | packets_sent: state.packets_sent + 1}}

      _ ->
        {:noreply, state}
    end
  end

  defp start_peer_connection_if_available(opts) do
    if Code.ensure_loaded?(ExWebRTC.PeerConnection) and
         function_exported?(ExWebRTC.PeerConnection, :start_link, 1) do
      pc_opts = [
        ice_servers: Keyword.get(opts, :ice_servers, [%{urls: "stun:stun.l.google.com:19302"}])
      ]

      case apply(ExWebRTC.PeerConnection, :start_link, [pc_opts]) do
        {:ok, pc} ->
          sender_ids =
            case apply(ExWebRTC.PeerConnection, :add_transceiver, [pc, :audio, [direction: :sendrecv]]) do
              {:ok, transceiver} -> [transceiver.sender.id]
              {:error, reason} ->
                Logger.warning("Unable to create outgoing audio transceiver: #{inspect(reason)}")
                []
              _ -> []
            end

          {pc, sender_ids}

        {:error, reason} ->
          Logger.error("Unable to start ExWebRTC PeerConnection: #{inspect(reason)}")
          {nil, []}
      end
    else
      {nil, []}
    end
  rescue
    error ->
      Logger.error("Unable to initialize ExWebRTC PeerConnection: #{inspect(error)}")
      {nil, []}
  end

  defp generate_id(prefix),
    do: prefix <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
end
