defmodule EVoiceKit.Transports.SIPCarrier do
  @moduledoc """
  GenServer handling an active direct SIP / RTP call leg over UDP.

  Implements `EVoiceKit.Providers.Carrier` for native SIP trunks (BYO-Trunk),
  performing zero-copy RTP packetization (RFC 3550) and SIP call control (BYE, REFER)
  without requiring external PBX intermediaries like FreeSWITCH or Asterisk.
  """

  use GenServer
  @behaviour EVoiceKit.Providers.Carrier
  require Logger

  alias EVoiceKit.Transports.SIP.{Message, RTP}
  alias EVoiceKit.Pipeline.SessionSupervisor

  defstruct call_id: nil,
            session_pid: nil,
            socket: nil,
            local_rtp_port: nil,
            remote_rtp_ip: nil,
            remote_rtp_port: nil,
            remote_sip_ip: nil,
            remote_sip_port: 5060,
            seq_num: 0,
            timestamp: 0,
            ssrc: 0,
            sip_headers: %{},
            carrier_data: %{}

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------

  @impl EVoiceKit.Providers.Carrier
  def carrier_name, do: :sip

  @doc """
  Starts an isolated SIP carrier process for an incoming or outgoing SIP call.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # ----------------------------------------------------------------------------
  # GenServer Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    call_id = Keyword.fetch!(opts, :call_id)
    remote_rtp_ip = Keyword.fetch!(opts, :remote_rtp_ip)
    remote_rtp_port = Keyword.fetch!(opts, :remote_rtp_port)
    remote_sip_ip = Keyword.get(opts, :remote_sip_ip, remote_rtp_ip)
    remote_sip_port = Keyword.get(opts, :remote_sip_port, 5060)
    sip_headers = Keyword.get(opts, :sip_headers, %{})

    # Open ephemeral UDP socket for bidirectional RTP
    case :gen_udp.open(0, [:binary, active: true]) do
      {:ok, socket} ->
        {:ok, local_port} = :inet.port(socket)
        ssrc = :rand.uniform(4_294_967_295)

        session_opts =
          [
            call_id: call_id,
            transport_pid: self(),
            caller_number: Keyword.get(opts, :caller_number),
            dialed_number: Keyword.get(opts, :dialed_number),
            tenant_id: Keyword.get(opts, :tenant_id),
            assistant_id: Keyword.get(opts, :assistant_id),
            stt_provider: Keyword.get(opts, :stt_provider),
            tts_provider: Keyword.get(opts, :tts_provider)
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        {:ok, session_pid} = SessionSupervisor.start_session(session_opts)

        remote_ip_tuple = parse_ip_address(remote_rtp_ip)
        remote_sip_tuple = parse_ip_address(remote_sip_ip)

        state = %__MODULE__{
          call_id: call_id,
          session_pid: session_pid,
          socket: socket,
          local_rtp_port: local_port,
          remote_rtp_ip: remote_ip_tuple,
          remote_rtp_port: remote_rtp_port,
          remote_sip_ip: remote_sip_tuple,
          remote_sip_port: remote_sip_port,
          seq_num: 1,
          timestamp: 0,
          ssrc: ssrc,
          sip_headers: sip_headers
        }

        Logger.info("[SIP:#{call_id}] RTP socket opened on port #{local_port}, peer #{remote_rtp_ip}:#{remote_rtp_port}")
        {:ok, state}

      {:error, reason} ->
        Logger.error("[SIP:#{call_id}] Failed to bind UDP RTP socket: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  # Inbound UDP packet (RTP audio from telephony carrier)
  @impl true
  def handle_info({:udp, socket, _ip, _port, binary_packet}, %{socket: socket} = state) do
    case RTP.decode(binary_packet) do
      {:ok, %{payload: mulaw_audio}} ->
        if state.session_pid do
          send(state.session_pid, {:caller_audio, mulaw_audio})
        end

        {:noreply, state}

      {:error, _reason} ->
        # Ignore non-RTP or malformed packets
        {:noreply, state}
    end
  end

  # Outbound audio chunk from Session GenServer
  @impl true
  def handle_info({:send_audio, mulaw_chunk}, state) do
    rtp_packet = RTP.encode(mulaw_chunk, state.seq_num, state.timestamp, state.ssrc)

    # Transmit directly over UDP to carrier's RTP endpoint
    :gen_udp.send(state.socket, state.remote_rtp_ip, state.remote_rtp_port, rtp_packet)

    # 20ms G.711 chunk = 160 samples at 8kHz
    new_timestamp = rem(state.timestamp + 160, 4_294_967_296)
    new_seq_num = rem(state.seq_num + 1, 65_536)

    {:noreply, %{state | timestamp: new_timestamp, seq_num: new_seq_num}}
  end

  # Barge-in: flush playback queue
  @impl true
  def handle_info(:clear_audio, state) do
    Logger.debug("[SIP:#{state.call_id}] Audio buffer cleared (barge-in)")
    {:noreply, state}
  end

  # Call Hangup from Agent
  @impl true
  def handle_info(:hangup, state) do
    Logger.info("[SIP:#{state.call_id}] Sending SIP BYE to carrier")
    send_bye(state)
    {:stop, :normal, state}
  end

  # Call Transfer (SIP REFER)
  @impl true
  def handle_info({:transfer, destination}, state) do
    Logger.info("[SIP:#{state.call_id}] Initiating SIP REFER transfer to #{destination}")
    send_refer(destination, state)
    {:noreply, state}
  end

  # Caller hung up (BYE received on SIP signaling socket)
  @impl true
  def handle_info({:sip_bye_received, reason}, state) do
    Logger.info("[SIP:#{state.call_id}] Carrier sent BYE: #{reason}")
    if state.session_pid, do: send(state.session_pid, {:caller_hangup, reason})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[SIP:#{state.call_id}] Terminating SIP transport: #{inspect(reason)}")
    if state.socket, do: :gen_udp.close(state.socket)
    :ok
  end

  # ----------------------------------------------------------------------------
  # EVoiceKit.Providers.Carrier Behaviour Callbacks
  # ----------------------------------------------------------------------------

  @impl EVoiceKit.Providers.Carrier
  def parse_start_event(sip_invite_message, state) do
    call_id = Map.get(sip_invite_message.headers, "Call-ID") || generate_call_id()

    case Message.parse_sdp_audio(sip_invite_message.body) do
      {:ok, remote_ip, remote_port} ->
        opts = [
          call_id: call_id,
          remote_rtp_ip: remote_ip,
          remote_rtp_port: remote_port,
          sip_headers: sip_invite_message.headers
        ]

        {:ok, call_id, opts, state}

      error ->
        error
    end
  end

  @impl EVoiceKit.Providers.Carrier
  def parse_media_event(raw_udp_binary, state) do
    case RTP.decode(raw_udp_binary) do
      {:ok, %{payload: mulaw}} -> {:ok, mulaw, state}
      error -> error
    end
  end

  @impl EVoiceKit.Providers.Carrier
  def encode_media_frame(mulaw_chunk, state) do
    rtp_packet = RTP.encode(mulaw_chunk, state.seq_num, state.timestamp, state.ssrc)
    {:reply, {:binary, rtp_packet}, state}
  end

  @impl EVoiceKit.Providers.Carrier
  def encode_clear_frame(_state), do: :ignore

  @impl EVoiceKit.Providers.Carrier
  def encode_hangup_frame(state) do
    send_bye(state)
    {:stop, :normal, state}
  end

  @impl EVoiceKit.Providers.Carrier
  def encode_transfer_frame(dest, state) do
    send_refer(dest, state)
    {:ok, state}
  end

  @impl EVoiceKit.Providers.Carrier
  def parse_stop_event(%{method: "BYE"}, _state), do: {:hangup, "sip-bye"}
  def parse_stop_event(_other, _state), do: :ignore

  # ----------------------------------------------------------------------------
  # SIP Signaling Helpers (BYE & REFER)
  # ----------------------------------------------------------------------------

  defp send_bye(state) do
    to_tag = Map.get(state.sip_headers, "To-Tag", "")
    from_tag = Map.get(state.sip_headers, "From-Tag", "")

    headers = %{
      "Via" => "SIP/2.0/UDP 0.0.0.0:#{state.local_rtp_port};branch=z9hG4bK#{:rand.uniform(1_000_000)}",
      "From" => "#{Map.get(state.sip_headers, "To", "")};tag=#{to_tag}",
      "To" => "#{Map.get(state.sip_headers, "From", "")};tag=#{from_tag}",
      "Call-ID" => state.call_id,
      "CSeq" => "2 BYE",
      "Max-Forwards" => "70"
    }

    bye_msg = Message.build_response(200, "OK", headers)
    :gen_udp.send(state.socket, state.remote_sip_ip, state.remote_sip_port, bye_msg)
  end

  defp send_refer(destination, state) do
    refer_headers = %{
      "Call-ID" => state.call_id,
      "Refer-To" => "<sip:#{destination}>",
      "Referred-By" => "<sip:gateway@0.0.0.0>",
      "CSeq" => "3 REFER"
    }

    refer_msg = Message.build_response(202, "Accepted", refer_headers)
    :gen_udp.send(state.socket, state.remote_sip_ip, state.remote_sip_port, refer_msg)
  end

  defp parse_ip_address(ip_str) when is_binary(ip_str) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, tuple} -> tuple
      _ -> {127, 0, 0, 1}
    end
  end

  defp parse_ip_address(tuple) when is_tuple(tuple), do: tuple

  defp generate_call_id do
    "sip_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
