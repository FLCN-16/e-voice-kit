defmodule EVoiceKit.Transports.TwilioWebSocket do
  @moduledoc """
  WebSock handler for inbound Twilio Media Streams, implemented using `EVoiceKit.Transports.WebSocketCarrier`.
  """

  use EVoiceKit.Transports.WebSocketCarrier

  @impl EVoiceKit.Providers.Carrier
  def carrier_name, do: :twilio

  @impl EVoiceKit.Providers.Carrier
  def parse_start_event(%{"event" => "start", "start" => start_data}, state) do
    stream_sid = Map.fetch!(start_data, "streamSid")
    call_sid = Map.get(start_data, "callSid", stream_sid)
    custom_params = Map.get(start_data, "customParameters", %{})

    session_opts =
      [
        call_id: stream_sid,
        tenant_id: custom_params["tenant_id"],
        assistant_id: custom_params["assistant_id"],
        caller_number: custom_params["from"] || custom_params["caller_number"],
        dialed_number: custom_params["to"] || custom_params["dialed_number"],
        stt_provider: parse_provider(custom_params["stt_provider"]),
        tts_provider: parse_provider(custom_params["tts_provider"]),
        voice_id: custom_params["voice_id"],
        model_id: custom_params["model_id"],
        language_code: custom_params["language"] || custom_params["language_code"],
        speaker: custom_params["speaker"]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    carrier_data = %{call_sid: call_sid, custom_params: custom_params}
    {:ok, stream_sid, session_opts, %{state | carrier_data: carrier_data}}
  end

  def parse_start_event(_other, _state), do: :ignore

  @impl EVoiceKit.Providers.Carrier
  def parse_media_event(%{"event" => "media", "media" => %{"payload" => base64_payload}}, state) do
    case Base.decode64(base64_payload) do
      {:ok, mulaw_audio} -> {:ok, mulaw_audio, state}
      :error -> {:error, :invalid_base64}
    end
  end

  def parse_media_event(_other, _state), do: :ignore

  @impl EVoiceKit.Providers.Carrier
  def encode_media_frame(mulaw_chunk, state) do
    if state.call_id do
      payload = %{
        "event" => "media",
        "streamSid" => state.call_id,
        "media" => %{
          "payload" => Base.encode64(mulaw_chunk)
        }
      }

      {:reply, {:text, Jason.encode!(payload)}, state}
    else
      :ignore
    end
  end

  @impl EVoiceKit.Providers.Carrier
  def encode_clear_frame(state) do
    if state.call_id do
      clear_payload = %{"event" => "clear", "streamSid" => state.call_id}
      {:reply, {:text, Jason.encode!(clear_payload)}, state}
    else
      :ignore
    end
  end

  @impl EVoiceKit.Providers.Carrier
  def encode_mark_frame(mark_name, state) do
    if state.call_id do
      payload = %{
        "event" => "mark",
        "streamSid" => state.call_id,
        "mark" => %{"name" => mark_name}
      }
      {:reply, {:text, Jason.encode!(payload)}, state}
    else
      :ignore
    end
  end

  # Handle Twilio connected event
  def handle_custom_in(%{"event" => "connected"}, state) do
    Logger.debug("[Twilio] Telephony stream connected")
    {:ok, state}
  end

  def handle_custom_in(_other, state), do: {:ok, state}

  defp parse_provider(nil), do: nil
  defp parse_provider(str) when is_binary(str) do
    case String.downcase(String.trim(str)) do
      "deepgram" -> :deepgram
      "assemblyai" -> :assemblyai
      "sarvam" -> :sarvam
      "cartesia" -> :cartesia
      "elevenlabs" -> :elevenlabs
      "fishaudio" -> :fishaudio
      "fish_audio" -> :fishaudio
      _ -> nil
    end
  end
end
