defmodule EVoiceKit.Providers.ProviderMacroTest do
  use ExUnit.Case, async: true

  alias EVoiceKit.Clients.{WhisperSTT, OpenAITTS}

  describe "EVoiceKit.Providers.STT Base Class" do
    test "WhisperSTT builds connection with expected parameters" do
      assert {:ok, url, headers, state} = WhisperSTT.build_connection("call_whisper_1", [language_code: "es"])
      assert url =~ "language=es"
      assert url =~ "sample_rate=8000"
      assert is_list(headers)
      assert state.language == "es"
    end

    test "WhisperSTT parses speech detection and transcription events" do
      state = %{}

      start_json = Jason.encode!(%{"event" => "speech_started"})
      assert {:speech_started, ^state} = WhisperSTT.parse_speech_event({:text, start_json}, state)

      trans_json = Jason.encode!(%{"text" => "Hello world", "is_final" => true})
      assert {:transcript, "Hello world", true, true, ^state} =
               WhisperSTT.parse_speech_event({:text, trans_json}, state)
    end

    test "WhisperSTT encodes clean EOF close frame" do
      assert {:ok, {:text, json_frame}} = WhisperSTT.encode_close_frame(%{})
      assert Jason.decode!(json_frame)["type"] == "eof"
    end
  end

  describe "EVoiceKit.Providers.TTS Base Class" do
    test "OpenAITTS builds connection with realtime endpoint and auth" do
      assert {:ok, url, headers, state} = OpenAITTS.build_connection("call_openai_1", [voice_id: "shimmer", api_key: "test_key"])
      assert url =~ "wss://api.openai.com/v1/realtime"
      assert {"Authorization", "Bearer test_key"} in headers
      assert state.voice == "shimmer"
    end

    test "OpenAITTS encodes text frame with pcm16 output format" do
      state = %{provider_state: %{voice: "alloy"}}
      assert {:reply, {:text, json_frame}, _} = OpenAITTS.encode_text_frame("Please hold on.", true, state)

      decoded = Jason.decode!(json_frame)
      assert decoded["type"] == "response.create"
      assert decoded["response"]["instructions"] =~ "Please hold on."
      assert decoded["response"]["output_audio_format"] == "pcm16"
    end

    test "OpenAITTS parses audio delta and turn completion" do
      state = %{}
      raw_pcm = <<0, 1, 2, 3, 4, 5>>
      b64 = Base.encode64(raw_pcm)

      audio_json = Jason.encode!(%{"type" => "response.audio.delta", "delta" => b64})
      assert {:audio, ^raw_pcm, ^state} = OpenAITTS.parse_audio_event({:text, audio_json}, state)

      done_json = Jason.encode!(%{"type" => "response.audio.done"})
      assert {:turn_completed, ^state} = OpenAITTS.parse_audio_event({:text, done_json}, state)
    end

    test "OpenAITTS encodes abort frame on barge-in" do
      assert {:reply, {:text, cancel_json}, _} = OpenAITTS.encode_abort_frame(%{})
      assert Jason.decode!(cancel_json)["type"] == "response.cancel"
    end
  end
end
