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
    client_encs = payload["client_encoders"] || payload["encoders"] || ["none"]
    client_decs = payload["client_decoders"] || payload["decoders"] || ["none"]

    case Negotiation.propose(state.negotiation, client_version, client_encs, client_decs) do
      {:ok, updated_neg} ->
        server_hello = %{
          "type" => "server_hello",
          "negotiation_id" => updated_neg.negotiation_id,
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

  defp dispatch_message(%__MODULE__{state: :negotiating} = state, :client_ready, payload, req_id) do
    case Negotiation.handle_client_ready(state.negotiation, payload) do
      {:ok, updated_neg, server_ready_payload} ->
        server_ready =
          Map.merge(server_ready_payload, %{
            "session_id" => state.session_id,
            "compression_active" => true,
            "c2s" => to_string(updated_neg.chosen_c2s_algorithm),
            "s2c" => to_string(updated_neg.chosen_s2c_algorithm)
          })

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

    case Token.verify(token_str) do
      {:ok, claims} ->
        tenant_id = claims["tenant_id"]
        room_name = claims["room"]
        identity = claims["identity"]
        permissions = claims["permissions"]

        valid_claims =
          Enum.all?([tenant_id, room_name, identity], &(is_binary(&1) and byte_size(&1) > 0)) and
            is_map(permissions) and
            Enum.all?(["can_publish", "can_subscribe", "can_publish_data"], fn key ->
              is_boolean(Map.get(permissions, key))
            end)

        if not valid_claims do
          reject_join(state, req_id, :invalid_claims)
        else
          room_coord_pid = get_or_start_room(tenant_id, room_name)

          if not is_pid(room_coord_pid) do
            reject_join(state, req_id, :room_unavailable)
          else
            case RoomCoordinator.join_participant(
                   room_coord_pid,
                   identity,
                   session_pid: self(),
                   permissions: permissions
                 ) do
              {:ok, participant} ->
                router_pid = RoomCoordinator.get_router(room_coord_pid)

                case PeerConnectionOwner.start_link(
                       participant_sid: participant.participant_sid,
                       router_pid: router_pid,
                       session_pid: self()
                     ) do
                  {:ok, pc_pid} ->
                    new_state = %{
                      state
                      | state: :connected,
                        room_id: {tenant_id, room_name},
                        room_coordinator: room_coord_pid,
                        participant_id: participant.participant_sid,
                        peer_connection_pid: pc_pid,
                        permissions: permissions,
                        authenticated: true
                    }

                    join_response = %{
                      "type" => "join_room_response",
                      "room" => room_name,
                      "tenant_id" => tenant_id,
                      "participant_id" => participant.participant_sid,
                      "session_id" => state.session_id,
                      "status" => "joined",
                      "permissions" => permissions
                    }

                    {:ok, resp_bin} = encode_outbound(new_state, :join_room_response, join_response, req_id)
                    {:reply, {:ok, [resp_bin]}, new_state}

                  {:error, reason} ->
                    RoomCoordinator.leave_participant(room_coord_pid, participant.participant_sid)
                    reject_join(state, req_id, {:peer_connection_start_failed, reason})
                end

              {:error, reason} ->
                reject_join(state, req_id, reason)
            end
          end
        end

      {:error, reason} ->
        Logger.warning("Join rejected in session #{state.session_id}: unauthorized (#{inspect(reason)})")
        reject_join(state, req_id, :unauthorized)
    end
  end

  defp reject_join(state, req_id, reason) do
    err = Protocol.build_error(:unauthorized, "Room admission rejected: #{inspect(reason)}", req_id)
    {:ok, err_bin} = encode_outbound(state, :error, err, req_id)
    {:reply, {:error, :unauthorized, [err_bin]}, state}
  end

  defp dispatch_message(%__MODULE__{state: :connected} = state, :ping, payload, req_id) do
    pong = %{"type" => "pong", "timestamp" => payload["timestamp"] || System.system_time(:millisecond)}
    {:ok, resp_bin} = encode_outbound(state, :pong, pong, req_id)
    {:reply, {:ok, [resp_bin]}, state}
  end

  # Remote SDP Offer from client -> apply to PeerConnectionOwner and return answer
  defp dispatch_message(%__MODULE__{state: :connected} = state, :sdp_offer, payload, req_id) do
    sdp = payload["sdp"] || ""

    case if(is_pid(state.peer_connection_pid),
           do: PeerConnectionOwner.apply_offer(state.peer_connection_pid, sdp),
           else: {:error, :peer_connection_unavailable}) do
      {:ok, answer_sdp} ->
        sdp_answer = %{"type" => "sdp_answer", "sdp" => answer_sdp, "offer_received" => true}
        {:ok, resp_bin} = encode_outbound(state, :sdp_answer, sdp_answer, req_id)
        {:reply, {:ok, [resp_bin]}, state}

      {:error, reason} ->
        err = Protocol.build_error(:negotiation_failed, "SDP negotiation failed: #{inspect(reason)}", req_id)
        {:ok, err_bin} = encode_outbound(state, :error, err, req_id)
        {:reply, {:error, :negotiation_failed, [err_bin]}, state}
    end
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
    if state.permissions["can_publish"] == true and is_pid(state.room_coordinator) do
      track_params = %{
        kind: payload["kind"] || "audio",
        source: payload["source"] || "microphone",
        payload_type: payload["payload_type"] || 111,
        ssrc: payload["ssrc"] || 0
      }

      case RoomCoordinator.publish_track(state.room_coordinator, state.participant_id, track_params) do
        {:ok, track_sid} ->
          track_published = %{
            "type" => "track_published",
            "track_sid" => track_sid,
            "kind" => track_params.kind,
            "source" => track_params.source
          }
          {:ok, resp_bin} = encode_outbound(state, :track_published, track_published, req_id)
          {:reply, {:ok, [resp_bin]}, state}

        {:error, reason} ->
          err = Protocol.build_error(:internal_error, "Track publication failed: #{inspect(reason)}", req_id)
          {:ok, err_bin} = encode_outbound(state, :error, err, req_id)
          {:reply, {:error, reason, [err_bin]}, state}
      end
    else
      err = Protocol.build_error(:permission_denied, "Publish permission denied", req_id)
      {:ok, err_bin} = encode_outbound(state, :error, err, req_id)
      {:reply, {:error, :permission_denied, [err_bin]}, state}
    end
  end

  # Subscribe Track
  defp dispatch_message(%__MODULE__{state: :connected} = state, :subscribe_track, payload, req_id) do
    track_sid = payload["track_sid"]

    cond do
      state.permissions["can_subscribe"] != true ->
        subscription_error(state, req_id, :permission_denied)

      not is_binary(track_sid) ->
        subscription_error(state, req_id, :invalid_track_sid)

      not is_pid(state.room_coordinator) or not is_pid(state.peer_connection_pid) ->
        subscription_error(state, req_id, :room_unavailable)

      true ->
        case RoomCoordinator.subscribe_track(
               state.room_coordinator,
               state.participant_id,
               track_sid,
               state.peer_connection_pid
             ) do
          {:ok, _down_track} ->
            response = %{"type" => "track_subscribed", "track_sid" => track_sid, "status" => "subscribed"}
            {:ok, resp_bin} = encode_outbound(state, :track_subscribed, response, req_id)
            {:reply, {:ok, [resp_bin]}, state}

          {:error, reason} ->
            subscription_error(state, req_id, reason)
        end
    end
  end

  defp subscription_error(state, req_id, reason) do
    err = Protocol.build_error(:permission_denied, "Subscription rejected: #{inspect(reason)}", req_id)
    {:ok, err_bin} = encode_outbound(state, :error, err, req_id)
    {:reply, {:error, reason, [err_bin]}, state}
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

    outbound_algorithm =
      case state.negotiation do
        %Negotiation{state: :active, server_to_client: algorithm} when is_atom(algorithm) ->
          algorithm

        _ ->
          :none
      end

    case BoundedEncoder.encode(json_bytes, outbound_algorithm, msg_type, request_id: req_id) do
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

  defp get_or_start_room(tenant_id, room_name) do
    case Registry.lookup(tenant_id, room_name) do
      {:ok, pid} ->
        pid

      _ ->
        case RoomDynamicSupervisor.start_room(room_name, tenant_id: tenant_id) do
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
