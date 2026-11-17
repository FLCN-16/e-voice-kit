defmodule VoiceGateway.Transports.TelnyxWebSocket do
  @moduledoc """
  WebSock handler for inbound Telnyx Media Streaming, implemented using `VoiceGateway.Transports.WebSocketCarrier`.
  """

  use VoiceGateway.Transports.WebSocketCarrier

  @impl VoiceGateway.Providers.Carrier
  def carrier_name, do: :telnyx

  @impl VoiceGateway.Providers.Carrier
  def parse_start_event(%{"event" => "start", "stream_id" => stream_id} = start_msg, state) do
    call_control_id = Map.get(start_msg, "call_control_id", stream_id)
    client_state = decode_client_state(Map.get(start_msg, "client_state"))

    session_opts =
      [
        call_id: stream_id,
        tenant_id: client_state["tenant_id"],
        assistant_id: client_state["assistant_id"],
        caller_number: client_state["from"] || client_state["caller_number"],
        dialed_number: client_state["to"] || client_state["dialed_number"],
        stt_provider: parse_provider(client_state["stt_provider"]),
        tts_provider: parse_provider(client_state["tts_provider"]),
        voice_id: client_state["voice_id"],
        model_id: client_state["model_id"],
        language_code: client_state["language"] || client_state["language_code"],
        speaker: client_state["speaker"]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    carrier_data = %{call_control_id: call_control_id, client_state: client_state}
    {:ok, stream_id, session_opts, %{state | carrier_data: carrier_data}}
  end

  def parse_start_event(_other, _state), do: :ignore

  @impl VoiceGateway.Providers.Carrier
  def parse_media_event(%{"event" => "media", "media" => %{"payload" => base64_payload}}, state) do
    case Base.decode64(base64_payload) do
      {:ok, mulaw_audio} -> {:ok, mulaw_audio, state}
      :error -> {:error, :invalid_base64}
    end
  end

  def parse_media_event(_other, _state), do: :ignore

  @impl VoiceGateway.Providers.Carrier
  def encode_media_frame(mulaw_chunk, state) do
    if state.call_id do
      payload = %{
        "event" => "media",
        "stream_id" => state.call_id,
        "media" => %{
          "payload" => Base.encode64(mulaw_chunk)
        }
      }

      {:reply, {:text, Jason.encode!(payload)}, state}
    else
      :ignore
    end
  end

  @impl VoiceGateway.Providers.Carrier
  def encode_clear_frame(state) do
    if state.call_id do
      clear_payload = %{"event" => "clear", "stream_id" => state.call_id}
      {:reply, {:text, Jason.encode!(clear_payload)}, state}
    else
      :ignore
    end
  end

  @impl VoiceGateway.Providers.Carrier
  def encode_mark_frame(mark_name, state) do
    if state.call_id do
      payload = %{
        "event" => "mark",
        "stream_id" => state.call_id,
        "mark" => %{"name" => mark_name}
      }
      {:reply, {:text, Jason.encode!(payload)}, state}
    else
      :ignore
    end
  end

  # Helper: Decodes base64-encoded client state from Telnyx Call Control
  defp decode_client_state(nil), do: %{}

  defp decode_client_state(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, json_str} ->
        case Jason.decode(json_str) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      :error ->
        %{}
    end
  end

  defp decode_client_state(_), do: %{}

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
