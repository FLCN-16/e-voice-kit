defmodule VoiceGateway.Clients.OpenAITTS do
  @moduledoc """
  Streaming TTS client for OpenAI Realtime Speech synthesis endpoints.

  Demonstrates how to implement a new TTS provider in under 50 lines of code
  using the `VoiceGateway.Providers.TTS` base class macro.
  """

  use VoiceGateway.Providers.TTS, audio_format: :pcm_16

  @impl VoiceGateway.Providers.TTS
  def build_connection(call_id, opts) do
    api_key = opts[:api_key] || Application.get_env(:voice_gateway, :openai_api_key)
    voice = opts[:voice_id] || "alloy"
    url = "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview"

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"OpenAI-Beta", "realtime=v1"}
    ]

    {:ok, url, headers, %{call_id: call_id, voice: voice}}
  end

  @impl VoiceGateway.Providers.TTS
  def encode_text_frame(text, _continue?, state) do
    payload = %{
      "type" => "response.create",
      "response" => %{
        "modalities" => ["audio"],
        "instructions" => "Speak the text naturally: #{text}",
        "voice" => state.provider_state.voice,
        "output_audio_format" => "pcm16"
      }
    }

    {:reply, {:text, Jason.encode!(payload)}, state}
  end

  @impl VoiceGateway.Providers.TTS
  def parse_audio_event({:text, json_str}, state) do
    case Jason.decode(json_str) do
      {:ok, %{"type" => "response.audio.delta", "delta" => b64_pcm}} ->
        case Base.decode64(b64_pcm) do
          {:ok, pcm_bytes} -> {:audio, pcm_bytes, state}
          :error -> :ignore
        end

      {:ok, %{"type" => "response.audio.done"}} ->
        {:turn_completed, state}

      _ ->
        :ignore
    end
  end

  def parse_audio_event(_other, _state), do: :ignore

  @impl VoiceGateway.Providers.TTS
  def encode_abort_frame(state) do
    cancel_payload = %{"type" => "response.cancel"}
    {:reply, {:text, Jason.encode!(cancel_payload)}, state}
  end
end
