defmodule EVoiceKit.Providers.Carrier do
  @moduledoc """
  Pluggable behaviour and contract for Telephony Carrier Transports.

  Any carrier provider (Twilio, Telnyx, Vonage, Plivo, Bandwidth, SIP/RTP, WebRTC)
  conforms to this contract to handle call ingress, protocol serialization, bidirectional
  audio streaming, and call control events (hangup, transfer, barge-in buffer flush).

  ## Developer Experience
  To implement a new WebSocket-based carrier in minutes, developers can use the
  `EVoiceKit.Transports.WebSocketCarrier` base class macro, which implements
  the complete `WebSock` protocol and supervision boilerplate automatically:

      defmodule EVoiceKit.Transports.MyCarrierWebSocket do
        use EVoiceKit.Transports.WebSocketCarrier

        @impl true
        def carrier_name, do: :my_carrier

        @impl true
        def parse_start_event(%{"event" => "call.start", "callId" => id} = payload, state) do
          session_opts = [
            call_id: id,
            caller_number: payload["from"],
            dialed_number: payload["to"]
          ]
          {:ok, id, session_opts, state}
        end

        @impl true
        def parse_media_event(%{"event" => "call.media", "audio" => b64}, state) do
          case Base.decode64(b64) do
            {:ok, mulaw} -> {:ok, mulaw, state}
            :error -> {:error, :invalid_base64}
          end
        end

        @impl true
        def encode_media_frame(mulaw_chunk, state) do
          payload = %{
            "event" => "call.media",
            "audio" => Base.encode64(mulaw_chunk)
          }
          {:reply, {:text, Jason.encode!(payload)}, state}
        end

        @impl true
        def encode_clear_frame(state) do
          payload = %{"event" => "call.clear"}
          {:reply, {:text, Jason.encode!(payload)}, state}
        end
      end
  """

  @type call_id :: binary()
  @type session_opts :: keyword()
  @type mulaw_audio :: binary()
  @type carrier_state :: map() | struct()
  @type wire_frame :: {:text, binary()} | {:binary, binary()}

  @doc """
  Unique atom identifying the carrier (e.g. `:twilio`, `:telnyx`, `:vonage`, `:sip`).
  """
  @callback carrier_name() :: atom()

  @doc """
  Parses an incoming carrier event to detect call setup/start.
  Returns `{:ok, call_id, session_opts, new_state}`, `:ignore`, or `{:error, term()}`.
  """
  @callback parse_start_event(payload :: term(), state :: carrier_state()) ::
              {:ok, call_id(), session_opts(), carrier_state()}
              | :ignore
              | {:error, term()}

  @doc """
  Parses an incoming carrier media event to extract raw 8kHz G.711 μ-law audio bytes.
  Returns `{:ok, mulaw_audio, new_state}`, `:ignore`, or `{:error, term()}`.
  """
  @callback parse_media_event(payload :: term(), state :: carrier_state()) ::
              {:ok, mulaw_audio(), carrier_state()}
              | :ignore
              | {:error, term()}

  @doc """
  Encodes synthesized G.711 μ-law audio chunks into the carrier's wire transmission format.
  Returns `{:reply, wire_frame(), new_state}`, `{:ok, new_state}`, or `:ignore`.
  """
  @callback encode_media_frame(mulaw_chunk :: binary(), state :: carrier_state()) ::
              {:reply, wire_frame(), carrier_state()}
              | {:ok, carrier_state()}
              | :ignore

  @doc """
  Encodes a barge-in buffer flush / clear command to stop audio playback on the carrier side immediately.
  """
  @callback encode_clear_frame(state :: carrier_state()) ::
              {:reply, wire_frame(), carrier_state()}
              | {:ok, carrier_state()}
              | :ignore

  @doc """
  Encodes a playback synchronization mark to track when audio finishes playing on the caller's handset.
  """
  @callback encode_mark_frame(mark_name :: binary(), state :: carrier_state()) ::
              {:reply, wire_frame(), carrier_state()}
              | {:ok, carrier_state()}
              | :ignore

  @doc """
  Encodes a call termination / hangup frame to the carrier.
  """
  @callback encode_hangup_frame(state :: carrier_state()) ::
              {:reply, wire_frame(), carrier_state()}
              | {:stop, reason :: term(), carrier_state()}
              | :ignore

  @doc """
  Encodes a call transfer request (e.g. SIP REFER or carrier transfer command).
  """
  @callback encode_transfer_frame(destination :: binary(), state :: carrier_state()) ::
              {:reply, wire_frame(), carrier_state()}
              | {:ok, carrier_state()}
              | :ignore

  @doc """
  Parses a carrier disconnect/stop event.
  Returns `{:hangup, reason}`, `:ignore`, or `{:error, term()}`.
  """
  @callback parse_stop_event(payload :: term(), state :: carrier_state()) ::
              {:hangup, reason :: binary()}
              | :ignore
              | {:error, term()}

  @optional_callbacks [
    encode_clear_frame: 1,
    encode_mark_frame: 2,
    encode_hangup_frame: 1,
    encode_transfer_frame: 2,
    parse_stop_event: 2
  ]
end
