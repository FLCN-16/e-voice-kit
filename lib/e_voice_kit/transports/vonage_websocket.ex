defmodule EVoiceKit.Transports.VonageWebSocket do
  @moduledoc """
  WebSock carrier handler for Vonage (Nexmo) Voice WebSockets.

  Demonstrates how easy it is to implement a new telephony carrier using
  `EVoiceKit.Transports.WebSocketCarrier`.
  """

  use EVoiceKit.Transports.WebSocketCarrier

  @impl EVoiceKit.Providers.Carrier
  def carrier_name, do: :vonage

  @impl EVoiceKit.Providers.Carrier
  def parse_start_event(%{"event" => "websocket:connected"} = msg, state) do
    call_id = msg["uuid"] || UUID.uuid4()

    session_opts = [
      call_id: call_id,
      caller_number: msg["from"],
      dialed_number: msg["to"],
      tenant_id: msg["tenant_id"],
      assistant_id: msg["assistant_id"]
    ]

    {:ok, call_id, session_opts, state}
  end

  def parse_start_event(_other, _state), do: :ignore

  @impl EVoiceKit.Providers.Carrier
  def parse_media_event(%{"event" => "audio", "data" => base64_payload}, state) do
    case Base.decode64(base64_payload) do
      {:ok, mulaw_audio} -> {:ok, mulaw_audio, state}
      :error -> {:error, :invalid_base64}
    end
  end

  def parse_media_event(_other, _state), do: :ignore

  @impl EVoiceKit.Providers.Carrier
  def encode_media_frame(mulaw_chunk, state) do
    payload = %{
      "event" => "audio",
      "data" => Base.encode64(mulaw_chunk)
    }

    {:reply, {:text, Jason.encode!(payload)}, state}
  end

  @impl EVoiceKit.Providers.Carrier
  def encode_clear_frame(_state) do
    payload = %{"event" => "clear"}
    {:reply, {:text, Jason.encode!(payload)}, _state}
  end
end
