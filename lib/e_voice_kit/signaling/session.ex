defmodule EVoiceKit.Signaling.Session do
  @moduledoc """
  Stateful signaling session managing capability negotiation, room attachment,
  and bidirectional message framing for one client connection.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 7 & 8).
  """

  use GenServer
  require Logger

  alias EVoiceKit.Compression.{BoundedDecoder, BoundedEncoder, Envelope, Negotiation}
  alias EVoiceKit.Signaling.Protocol

  defstruct [
    :session_id,
    :transport_pid,
    :room_id,
    :participant_id,
    :peer_connection_pid,
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
    neg = Negotiation.new()

    state = %__MODULE__{
      session_id: session_id,
      transport_pid: transport_pid,
      state: :await_client_hello,
      negotiation: neg
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
      {:error, reason} = err ->
        Logger.warning("Signaling session frame rejection: #{inspect(reason)}")
        {:reply, err, state}
    end
  end

  # --- Message Dispatcher ---

  defp dispatch_message(%__MODULE__{state: :await_client_hello} = state, :client_hello, payload, req_id) do
    case Negotiation.handle_client_hello(state.negotiation, payload) do
      {:ok, updated_neg, server_hello} ->
        # ServerHello MUST be uncompressed (ADR-0002)
        new_state = %{state | state: :negotiating, negotiation: updated_neg}
        {:ok, resp_bin} = encode_uncompressed(Protocol.msg_type(:server_hello), server_hello, req_id)
        {:reply, {:ok, [resp_bin]}, new_state}

      {:error, reason} ->
        error_resp = Protocol.build_error(:compression_mismatch, "Failed to negotiate capabilities", req_id)
        {:ok, err_bin} = encode_uncompressed(Protocol.msg_type(:error), error_resp, req_id)
        {:reply, {:error, reason, [err_bin]}, %{state | state: :closed}}
    end
  end

  defp dispatch_message(%__MODULE__{state: :negotiating} = state, :client_ready, payload, req_id) do
    case Negotiation.handle_client_ready(state.negotiation, payload) do
      {:ok, updated_neg, server_ready} ->
        # ServerReady MUST be uncompressed (ADR-0002)
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
    room_name = payload["room"] || "default"
    participant_identity = payload["identity"] || generate_id("user_")

    new_state = %{
      state
      | state: :connected,
        room_id: room_name,
        participant_id: participant_identity,
        authenticated: true
    }

    join_response = %{
      "type" => "join_room_response",
      "room" => room_name,
      "participant_id" => participant_identity,
      "session_id" => state.session_id,
      "status" => "joined"
    }

    {:ok, resp_bin} = encode_outbound(new_state, :join_room_response, join_response, req_id)
    {:reply, {:ok, [resp_bin]}, new_state}
  end

  defp dispatch_message(%__MODULE__{state: :connected} = state, :ping, payload, req_id) do
    pong = %{"type" => "pong", "timestamp" => payload["timestamp"] || System.system_time(:millisecond)}
    {:ok, resp_bin} = encode_outbound(state, :pong, pong, req_id)
    {:reply, {:ok, [resp_bin]}, state}
  end

  defp dispatch_message(%__MODULE__{state: :connected} = state, :sdp_offer, payload, req_id) do
    # Echo / answer negotiation
    sdp = payload["sdp"] || ""
    sdp_answer = %{
      "type" => "sdp_answer",
      "sdp" => "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n",
      "offer_received" => byte_size(sdp) > 0
    }
    {:ok, resp_bin} = encode_outbound(state, :sdp_answer, sdp_answer, req_id)
    {:reply, {:ok, [resp_bin]}, state}
  end

  defp dispatch_message(%__MODULE__{state: :connected} = state, :publish_track, payload, req_id) do
    track_sid = generate_id("TR_")
    track_published = %{
      "type" => "track_published",
      "track_sid" => track_sid,
      "kind" => payload["kind"] || "audio",
      "source" => payload["source"] || "microphone"
    }
    {:ok, resp_bin} = encode_outbound(state, :track_published, track_published, req_id)
    {:reply, {:ok, [resp_bin]}, state}
  end

  defp dispatch_message(%__MODULE__{state: :connected} = state, :leave_room, _payload, req_id) do
    new_state = %{state | state: :closed, room_id: nil}
    resp = %{"type" => "left_room", "status" => "ok"}
    {:ok, resp_bin} = encode_outbound(new_state, :leave_room, resp, req_id)
    {:reply, {:ok, [resp_bin]}, new_state}
  end

  defp dispatch_message(state, unknown_msg, _payload, req_id) do
    err = Protocol.build_error(:internal_error, "Unexpected message: #{inspect(unknown_msg)} in state #{state.state}", req_id)
    {:ok, err_bin} = encode_outbound(state, :error, err, req_id)
    {:reply, {:error, :unexpected_message, [err_bin]}, state}
  end

  # --- Internal Encoders & Decoders ---

  defp validate_inbound_compression(%__MODULE__{negotiation: nil}, _envelope), do: :ok

  defp validate_inbound_compression(%__MODULE__{negotiation: neg}, envelope) do
    if neg.state == :active do
      Negotiation.validate_inbound_algorithm(neg, envelope.algorithm)
    else
      # Pre-activation frames must be uncompressed (NONE)
      if envelope.compressed do
        {:error, :compressed_frame_before_negotiation_active}
      else
        :ok
      end
    end
  end

  defp encode_outbound(state, msg_type_atom, payload_map, req_id) do
    msg_type_int = Protocol.msg_type(msg_type_atom)
    json_binary = Jason.encode!(payload_map)

    # Determine outbound algorithm
    algo =
      if state.negotiation && state.negotiation.state == :active do
        state.negotiation.server_to_client || :none
      else
        :none
      end

    with {:ok, envelope} <- BoundedEncoder.encode(json_binary, algo, msg_type_int, request_id: req_id),
         {:ok, binary} <- Envelope.encode(envelope) do
      {:ok, binary}
    end
  end

  defp encode_uncompressed(msg_type_int, payload_map, req_id) do
    json_binary = Jason.encode!(payload_map)

    with {:ok, envelope} <-
           BoundedEncoder.encode(json_binary, :none, msg_type_int, request_id: req_id),
         {:ok, binary} <- Envelope.encode(envelope) do
      {:ok, binary}
    end
  end

  defp parse_json_payload(binary) do
    Jason.decode(binary)
  rescue
    e -> {:error, {:invalid_json, e}}
  end

  defp generate_id(prefix) do
    prefix <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
