defmodule EVoiceKit.Clients.WhisperSTT do
  @moduledoc """
  Streaming STT client for self-hosted Whisper / Faster-Whisper endpoints.

  Demonstrates how to implement a new STT provider in under 40 lines of code
  using the `EVoiceKit.Providers.STT` base class macro.
  """

  use EVoiceKit.Providers.STT, audio_format: :pcm_16

  @impl EVoiceKit.Providers.STT
  def build_connection(_call_id, opts) do
    base_url = opts[:url] || Application.get_env(:e_voice_kit, :whisper_url, "ws://localhost:9000/v1/stream")
    language = opts[:language_code] || "en"
    url = "#{base_url}?language=#{language}&sample_rate=8000"
    {:ok, url, [], %{language: language}}
  end

  @impl EVoiceKit.Providers.STT
  def parse_speech_event({:text, json_str}, state) do
    case Jason.decode(json_str) do
      {:ok, %{"event" => "speech_started"}} ->
        {:speech_started, state}

      {:ok, %{"text" => text, "is_final" => is_final}} ->
        {:transcript, text, is_final, is_final, state}

      _ ->
        :ignore
    end
  end

  def parse_speech_event(_other, _state), do: :ignore

  @impl EVoiceKit.Providers.STT
  def encode_close_frame(_state) do
    {:ok, {:text, Jason.encode!(%{"type" => "eof"})}}
  end
end
