defmodule EVoiceKit.Signaling.Session do
  @moduledoc """
  Stateful signaling session managing capability negotiation, room attachment,
  and bidirectional message framing for one client connection.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 7 & 8).
  """

  use GenServer
  require Logger

  alias EVoiceKit.Auth.Token
  alias EVoiceKit.Compression.{BoundedDecoder, BoundedEncoder, Envelope, Negotiation}
  alias EVoiceKit.Rooms.{Registry, RoomCoordinator, RoomDynamicSupervisor}
  alias EVoiceKit.RTC.PeerConnectionOwner
  alias EVoiceKit.Signaling.Protocol

  defstruct [
    :session_id,
    :transport_pid,
    :initial_token,
    :room_id,
    :room_coordinator,
    :participant_id,
    :peer_connection_pid,
    :permissions,
    state: :await_client_hello,
    negotiation: nil,
    authenticated: false,
    outbound_seq: 0
  ]

  @type state ::
          :await_client_hello
          | :negotiating
          | :authenticating
          | :signaling_ready
          | :connected
          | :closed

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Processes an inbound raw binary frame received from the transport (WebSocket).
  Returns `{:ok, [response_binary]}` or `{:error, reason}`.
  """
  def handle_frame(pid, binary_frame) when is_binary(binary_frame) do
    GenServer.call(pid, {:inbound_frame, binary_frame})
  end

  @doc """
  Sends an outbound message to the client, encoded and compressed according to negotiated policy.
  """
  def send_message(pid, message_type_atom, payload_map, request_id \\ 0) do
    GenServer.call(pid, {:outbound_message, message_type_atom, payload_map, request_id})
  end

  @doc """
  Gets the current state of the session.
  """
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    session_id = Keyword.get(opts, :session_id, generate_id("sess_"))
    transport_pid = Keyword.get(opts, :transport_pid, self())
    initial_token = Keyword.get(opts, :token)
    neg = Negotiation.new()

    state = %__MODULE__{
      session_id: session_id,
      transport_pid: transport_pid,
      initial_token: initial_token,
      state: :await_client_hello,
      negotiation: neg,
      permissions: %{
        "can_publish" => true,
        "can_subscribe" => true,
        "can_publish_data" => true
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:outbound_message, msg_type, payload_map, request_id}, _from, state) do
    case encode_outbound(state, msg_type, payload_map, request_id) do
      {:ok, binary} -> {:reply, {:ok, binary}, state}
      err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:inbound_frame, binary_frame}, _from, state) do
    with {:ok, envelope} <- Envelope.decode(binary_frame),
         :ok <- validate_inbound_compression(state, envelope),
         {:ok, plain_payload} <- BoundedDecoder.decode(envelope, []),
         {:ok, json_map} <- parse_json_payload(plain_payload) do
      msg_type = Protocol.msg_name(envelope.message_type)
      dispatch_message(state, msg_type, json_map, envelope.request_id)
    else
      {:error, reason} ->
        Logger.warning("Inbound frame error in session #{state.session_id}: #{inspect(reason)}")
        err_msg = Protocol.build_error(:frame_decode_error, "Frame decode error: #{inspect(reason)}", 0)
        {:ok, err_bin} = encode_uncompressed(Protocol.msg_type(:error), err_msg, 0)
        {:reply, {:error, reason, [err_bin]}, state}
    end
  end

  # Local ICE candidate emitted by PeerConnectionOwner -> forward to client via transport
  @impl true
  def handle_info({:local_ice_candidate, cand_map}, state) do
    if state.state == :connected and is_pid(state.transport_pid) do
      case encode_outbound(state, :ice_candidate, cand_map, 0) do
        {:ok, binary} ->
          send(state.transport_pid, {:push_message, binary})

        _ ->
          :ok
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.room_coordinator) and state.participant_id do
      RoomCoordinator.leave_participant(state.room_coordinator, state.participant_id)
    end

    if is_pid(state.peer_connection_pid) and Process.alive?(state.peer_connection_pid) do
      GenServer.stop(state.peer_connection_pid, :normal)
    end

    :ok
  end

  # --- Protocol Message Dispatchers ---

  defp dispatch_message(%__MODULE__{state: :await_client_hello} = state, :client_hello, payload, req_id) do
    client_version = payload["protocol_version"] || 1
    client_encs = payload["client_encoders"] || ["none"]
    client_decs = payload["client_decoders"] || ["none"]

    case Negotiation.propose(state.negotiation, client_version, client_encs, client_decs) do
      {:ok, updated_neg} ->
        server_hello = %{
          "type" => "server_hello",
          "protocol_version" => updated_neg.protocol_version,
          "chosen_c2s_algorithm" => to_string(updated_neg.chosen_c2s_algorithm),
          "chosen_s2c_algorithm" => to_string(updated_neg.chosen_s2c_algorithm),
          "session_id" => state.session_id
        }

        new_state = %{state | state: :negotiating, negotiation: updated_neg}
        {:ok, resp_bin} = encode_uncompressed(Protocol.msg_type(:server_hello), server_hello, req_id)
        {:reply, {:ok, [resp_bin]}, new_state}

      {:error, reason} ->
        error_resp = Protocol.build_error(:negotiation_failed, "Protocol capability negotiation failed", req_id)
        {:ok, err_bin} = encode_uncompressed(Protocol.msg_type(:error), error_resp, req_id)
        {:reply, {:error, reason, [err_bin]}, %{state | state: :closed}}
    end
  end

  defp dispatch_message(%__MODULE__{state: :negotiating} = state, :client_ready, _payload, req_id) do
    case Negotiation.confirm(state.negotiation) do
      {:ok, updated_neg} ->
        server_ready = %{
          "type" => "server_ready",
          "session_id" => state.session_id,
          "compression_active" => true,
          "c2s" => to_string(updated_neg.chosen_c2s_algorithm),
          "s2c" => to_string(updated_neg.chosen_s2c_algorithm)
        }

        new_state = %{state | state: :signaling_ready, negotiation: updated_neg}
        {:ok, resp_bin} = encode_uncompressed(Protocol.msg_type(:server_ready), server_ready, req_id)
        {:reply, {:ok, [resp_bin]}, new_state}

      {:error, reason} ->
        error_resp = Protocol.build_error(:internal_error, "Negotiation confirmation failed", req_id)
        {:ok, err_bin} = encode_uncompressed(Protocol.msg_type(:error), error_resp, req_id)
        {:reply, {:error, reason, [err_bin]}, %{state | state: :closed}}
    end
  end

  defp dispatch_message(%__MODULE__{state: state_name} = state, :join_room, payload, req_id)
       when state_name in [:signaling_ready, :connected] do
    token_str = payload["token"] || state.initial_token

    # Verify cryptographic token
    case Token.verify(token_str) do
      {:ok, claims} ->
        room_name = claims["room"] || payload["room"] || "default"
        identity = claims["identity"] || payload["identity"] || generate_id("user_")
        permissions = claims["permissions"] || state.permissions

        # Ensure RoomCoordinator is started
        room_coord_pid = get_or_start_room(room_name)
        router_pid = if is_pid(room_coord_pid), do: RoomCoordinator.get_router(room_coord_pid), else: nil

        # Start dedicated ExWebRTC PeerConnectionOwner
        {:ok, pc_pid} =
          PeerConnectionOwner.start_link(
            participant_sid: identity,
            router_pid: router_pid,
            session_pid: self()
          )

        # Join participant into RoomCoordinator
        participant_sid =
          case RoomCoordinator.join_participant(room_coord_pid, identity, session_pid: self(), permissions: permissions) do
            {:ok, participant} -> participant.participant_sid
            _ -> identity
          end

        new_state = %{
          state
          | state: :connected,
            room_id: room_name,
            room_coordinator: room_coord_pid,
            participant_id: participant_sid,
            peer_connection_pid: pc_pid,
            permissions: permissions,
            authenticated: true
        }

        join_response = %{
          "type" => "join_room_response",
          "room" => room_name,
          "participant_id" => participant_sid,
          "session_id" => state.session_id,
          "status" => "joined",
          "permissions" => permissions
        }

        {:ok, resp_bin} = encode_outbound(new_state, :join_room_response, join_response, req_id)
        {:reply, {:ok, [resp_bin]}, new_state}

      {:error, reason} ->
        Logger.warning("Join rejected in session #{state.session_id}: unauthorized (#{inspect(reason)})")
        err = Protocol.build_error(:unauthorized, "Authentication failed: #{inspect(reason)}", req_id)
        {:ok, err_bin} = encode_outbound(state, :error, err, req_id)
        {:reply, {:error, :unauthorized, [err_bin]}, state}
    end
  end

  defp dispatch_message(%__MODULE__{state: :connected} = state, :ping, payload, req_id) do
    pong = %{"type" => "pong", "timestamp" => payload["timestamp"] || System.system_time(:millisecond)}
    {:ok, resp_bin} = encode_outbound(state, :pong, pong, req_id)
    {:reply, {:ok, [resp_bin]}, state}
  end

  # Remote SDP Offer from client -> apply to PeerConnectionOwner and return answer
  defp dispatch_message(%__MODULE__{state: :connected} = state, :sdp_offer, payload, req_id) do
    sdp = payload["sdp"] || ""

    answer_sdp =
      if is_pid(state.peer_connection_pid) do
        case PeerConnectionOwner.apply_offer(state.peer_connection_pid, sdp) do
          {:ok, answer} -> answer
          _ -> "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"
        end
      else
        "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"
      end

    sdp_answer = %{
      "type" => "sdp_answer",
      "sdp" => answer_sdp,
      "offer_received" => byte_size(sdp) > 0
    }

    {:ok, resp_bin} = encode_outbound(state, :sdp_answer, sdp_answer, req_id)
    {:reply, {:ok, [resp_bin]}, state}
  end

  # Remote Trickle ICE Candidate from client -> apply to PeerConnectionOwner
  defp dispatch_message(%__MODULE__{state: :connected} = state, :ice_candidate, payload, _req_id) do
    if is_pid(state.peer_connection_pid) do
      PeerConnectionOwner.add_ice_candidate(state.peer_connection_pid, payload)
    end

    {:reply, {:ok, []}, state}
  end

  # Publish Track
  defp dispatch_message(%__MODULE__{state: :connected} = state, :publish_track, payload, req_id) do
    if state.permissions["can_publish"] == true do
      track_params = %{
        kind: payload["kind"] || "audio",
        source: payload["source"] || "microphone",
        payload_type: payload["payload_type"] || 111,
        ssrc: payload["ssrc"] || 0
      }

      track_sid =
        if is_pid(state.room_coordinator) do
          case RoomCoordinator.publish_track(state.room_coordinator, state.participant_id, track_params) do
            {:ok, sid} -> sid
            _ -> generate_id("TR_")
          end
        else
          generate_id("TR_")
        end

      track_published = %{
        "type" => "track_published",
        "track_sid" => track_sid,
        "kind" => track_params.kind,
        "source" => track_params.source
      }

      {:ok, resp_bin} = encode_outbound(state, :track_published, track_published, req_id)
      {:reply, {:ok, [resp_bin]}, state}
    else
      err = Protocol.build_error(:permission_denied, "Publish permission denied", req_id)
      {:ok, err_bin} = encode_outbound(state, :error, err, req_id)
      {:reply, {:error, :permission_denied, [err_bin]}, state}
    end
  end

  # Subscribe Track
  defp dispatch_message(%__MODULE__{state: :connected} = state, :subscribe_track, payload, req_id) do
    track_sid = payload["track_sid"]

    if state.permissions["can_subscribe"] == true and is_binary(track_sid) do
      if is_pid(state.room_coordinator) and is_pid(state.peer_connection_pid) do
        RoomCoordinator.subscribe_track(
          state.room_coordinator,
          state.participant_id,
          track_sid,
          state.peer_connection_pid
        )
      end

      track_subscribed = %{
        "type" => "track_subscribed",
        "track_sid" => track_sid,
        "status" => "subscribed"
      }

      {:ok, resp_bin} = encode_outbound(state, :track_subscribed, track_subscribed, req_id)
      {:reply, {:ok, [resp_bin]}, state}
    else
      err = Protocol.build_error(:permission_denied, "Subscribe permission denied", req_id)
      {:ok, err_bin} = encode_outbound(state, :error, err, req_id)
      {:reply, {:error, :permission_denied, [err_bin]}, state}
    end
  end

  defp dispatch_message(%__MODULE__{state: :connected} = state, :leave_room, _payload, req_id) do
    if is_pid(state.room_coordinator) and state.participant_id do
      RoomCoordinator.leave_participant(state.room_coordinator, state.participant_id)
    end

    new_state = %{state | state: :closed, room_id: nil, room_coordinator: nil}
    resp = %{"type" => "left_room", "status" => "ok"}
    {:ok, resp_bin} = encode_outbound(new_state, :leave_room, resp, req_id)
    {:reply, {:ok, [resp_bin]}, new_state}
  end

  defp dispatch_message(state, unknown_msg, _payload, req_id) do
    err =
      Protocol.build_error(
        :internal_error,
        "Unexpected message: #{inspect(unknown_msg)} in state #{state.state}",
        req_id
      )

    {:ok, err_bin} = encode_outbound(state, :error, err, req_id)
    {:reply, {:error, :unexpected_message, [err_bin]}, state}
  end

  # --- Internal Encoders & Decoders ---

  defp validate_inbound_compression(%__MODULE__{negotiation: nil}, _envelope), do: :ok

  defp validate_inbound_compression(%__MODULE__{negotiation: neg}, envelope) do
    if neg.state == :active do
      Negotiation.validate_inbound_algorithm(neg, envelope.algorithm)
    else
      if envelope.compressed do
        {:error, :compressed_frame_before_negotiation_active}
      else
        :ok
      end
    end
  end

  defp parse_json_payload(plain_binary) when is_binary(plain_binary) do
    if byte_size(plain_binary) == 0 do
      {:ok, %{}}
    else
      Jason.decode(plain_binary)
    end
  end

  defp encode_outbound(state, msg_type_atom, payload_map, req_id) do
    msg_type = Protocol.msg_type(msg_type_atom)
    {:ok, json_bytes} = Jason.encode(payload_map)

    case BoundedEncoder.encode(json_bytes, state.negotiation, message_type: msg_type, request_id: req_id) do
      {:ok, %Envelope{} = env} -> Envelope.encode(env)
      err -> err
    end
  end

  defp encode_uncompressed(msg_type, payload_map, req_id) do
    {:ok, json_bytes} = Jason.encode(payload_map)

    env = %Envelope{
      compressed: false,
      algorithm: :none,
      message_type: msg_type,
      request_id: req_id,
      plain_length: byte_size(json_bytes),
      payload: json_bytes
    }

    Envelope.encode(env)
  end

  defp get_or_start_room(room_name) do
    case Registry.lookup(room_name) do
      {:ok, pid} ->
        pid

      _ ->
        case RoomDynamicSupervisor.start_room(room_name) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
          _ -> nil
        end
    end
  end

  defp generate_id(prefix) do
    prefix <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
