defmodule EVoiceKit.Providers.EventsTest do
  use ExUnit.Case, async: true
  alias EVoiceKit.Providers.Events

  describe "normalize_carrier_event/1" do
    test "normalizes carrier socket events across Twilio, Telnyx, and Vonage" do
      assert Events.normalize_carrier_event(%{"event" => "connected"}) == :connected
      assert Events.normalize_carrier_event(%{"event" => "websocket:connected"}) == :connected
      assert Events.normalize_carrier_event(%{"event" => "start"}) == :call_start
      assert Events.normalize_carrier_event(%{"event" => "call.start"}) == :call_start
      assert Events.normalize_carrier_event(%{"event" => "media"}) == :call_media
      assert Events.normalize_carrier_event(%{"event" => "audio"}) == :call_media
      assert Events.normalize_carrier_event(%{"event" => "stop"}) == :call_stop
      assert Events.normalize_carrier_event(%{"event" => "disconnect"}) == :call_stop
      assert Events.normalize_carrier_event(%{"event" => "websocket:terminated"}) == :call_stop
      assert Events.normalize_carrier_event(%{"event" => "clear"}) == :clear
    end

    test "normalizes DTMF keypad touch-tones" do
      assert Events.normalize_carrier_event(%{"event" => "dtmf", "dtmf" => %{"digit" => "1"}}) == {:dtmf, "1"}
      assert Events.normalize_carrier_event(%{"event" => "dtmf", "digit" => "#"}) == {:dtmf, "#"}
      assert Events.normalize_carrier_event(%{"event" => "keypress", "key" => "9"}) == {:dtmf, "9"}
    end

    test "normalizes playback marks" do
      assert Events.normalize_carrier_event(%{"event" => "mark", "mark" => %{"name" => "greeting_done"}}) ==
               {:mark, "greeting_done"}

      assert Events.normalize_carrier_event(%{"event" => "mark", "name" => "turn_2"}) == {:mark, "turn_2"}
    end

    test "normalizes carrier errors" do
      assert Events.normalize_carrier_event(%{"event" => "error", "error" => "stream_timeout"}) ==
               {:error, "stream_timeout"}
    end
  end

  describe "normalize_webhook_status/1" do
    test "normalizes call lifecycle status across Twilio, Telnyx, and Vonage" do
      assert Events.normalize_webhook_status(%{"CallStatus" => "in-progress"}) == :call_answered
      assert Events.normalize_webhook_status(%{"event_type" => "call.answered"}) == :call_answered
      assert Events.normalize_webhook_status(%{"status" => "ringing"}) == :call_ringing
      assert Events.normalize_webhook_status(%{"CallStatus" => "completed"}) == :call_completed
      assert Events.normalize_webhook_status(%{"event_type" => "call.hangup"}) == :call_completed
      assert Events.normalize_webhook_status(%{"CallStatus" => "busy"}) == :call_busy
      assert Events.normalize_webhook_status(%{"CallStatus" => "no-answer"}) == :call_no_answer
      assert Events.normalize_webhook_status(%{"status" => "failed"}) == :call_failed
    end

    test "normalizes recording callback webhooks" do
      twilio_rec = %{
        "RecordingUrl" => "https://api.twilio.com/recordings/RE123",
        "RecordingDuration" => "45"
      }

      assert Events.normalize_webhook_status(twilio_rec) ==
               {:recording_ready, "https://api.twilio.com/recordings/RE123", 45}
    end
  end

  describe "normalize_stt_event/1" do
    test "normalizes speech onset across diverse vendor variations to :speech_started" do
      vendor_variants = [
        "SpeechStarted",
        "speech_started",
        "speech_start",
        "vad_start",
        "vad_started",
        "vad_detected",
        "speech_detected",
        "input_audio_buffer.speech_started",
        "PartialTranscript",
        :speech_started,
        :vad_started
      ]

      for variant <- vendor_variants do
        assert Events.normalize_stt_event(variant) == :speech_started,
               "Failed to normalize #{inspect(variant)} to :speech_started"
      end
    end

    test "normalizes speech endpointing across diverse vendor variations to :speech_ended" do
      vendor_variants = [
        "SpeechEnded",
        "speech_ended",
        "speech_final",
        "utterance_end",
        "utteranceend",
        "vad_end",
        "vad_stopped",
        "input_audio_buffer.speech_stopped",
        :speech_ended,
        :vad_ended
      ]

      for variant <- vendor_variants do
        assert Events.normalize_stt_event(variant) == :speech_ended,
               "Failed to normalize #{inspect(variant)} to :speech_ended"
      end
    end

    test "normalizes JSON maps with type or event keys" do
      assert Events.normalize_stt_event(%{"type" => "SpeechStarted"}) == :speech_started
      assert Events.normalize_stt_event(%{"event" => "vad_started"}) == :speech_started
      assert Events.normalize_stt_event(%{"message_type" => "PartialTranscript"}) == :speech_started
      assert Events.normalize_stt_event(%{"type" => "UtteranceEnd"}) == :speech_ended
      assert {:metadata, _} = Events.normalize_stt_event(%{"type" => "Metadata"})
      assert {:error, "quota_exceeded"} = Events.normalize_stt_event(%{"type" => "Error", "message" => "quota_exceeded"})
    end

    test "returns :ignore for unmapped events" do
      assert Events.normalize_stt_event("heartbeat") == :ignore
      assert Events.normalize_stt_event(%{"type" => "ping"}) == :ignore
    end
  end

  describe "normalize_tts_event/1" do
    test "normalizes playback and turn completion variants to :turn_completed" do
      variants = [
        "done",
        "turn_completed",
        "turn_complete",
        "response.audio.done",
        "playback_completed",
        "completed",
        "is_final",
        :turn_completed,
        :done
      ]

      for variant <- variants do
        assert Events.normalize_tts_event(variant) == :turn_completed,
               "Failed to normalize #{inspect(variant)} to :turn_completed"
      end
    end

    test "normalizes cancellation and interruption variants to :turn_aborted" do
      variants = [
        "canceled",
        "cancelled",
        "response.cancel",
        "interrupted",
        "aborted",
        "turn_aborted",
        :turn_aborted,
        :aborted
      ]

      for variant <- variants do
        assert Events.normalize_tts_event(variant) == :turn_aborted,
               "Failed to normalize #{inspect(variant)} to :turn_aborted"
      end
    end

    test "normalizes TTS JSON maps" do
      assert Events.normalize_tts_event(%{"type" => "response.audio.done"}) == :turn_completed
      assert Events.normalize_tts_event(%{"event" => "playback_done"}) == :turn_completed
      assert Events.normalize_tts_event(%{"done" => true}) == :turn_completed
      assert Events.normalize_tts_event(%{"is_final" => true}) == :turn_completed
      assert {:alignment, _} = Events.normalize_tts_event(%{"normalizedAlignment" => []})
      assert {:error, "synthesis_failed"} = Events.normalize_tts_event(%{"error" => "synthesis_failed"})
    end
  end
end
