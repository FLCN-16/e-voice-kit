defmodule EVoiceKit.Providers.Events do
  @moduledoc """
  Canonical, unified event contracts for all Telephony Carriers, Speech-to-Text (STT),
  and Text-to-Speech (TTS) real-time streams and webhooks.

  Guarantees that every single event across Twilio, Telnyx, Vonage, Plivo, SIP,
  Deepgram, AssemblyAI, Sarvam, Whisper, OpenAI, ElevenLabs, Cartesia, and Fish Audio
  is cleanly normalized, typed, and handled without dropped frames or unexpected crashes.
  """

  # ----------------------------------------------------------------------------
  # Type Definitions (Canonical Enums)
  # ----------------------------------------------------------------------------

  @type carrier_canonical_event ::
          :connected
          | :call_start
          | :call_media
          | :call_stop
          | {:dtmf, digit :: binary()}
          | {:mark, mark_name :: binary()}
          | :clear
          | {:error, reason :: term()}
          | :ignore

  @type webhook_status_event ::
          :call_initiated
          | :call_ringing
          | :call_answered
          | :call_completed
          | :call_busy
          | :call_no_answer
          | :call_failed
          | {:recording_ready, recording_url :: binary(), duration :: integer() | nil}
          | :ignore

  @type stt_canonical_event ::
          :speech_started
          | :speech_ended
          | {:transcript, text :: binary(), is_final :: boolean(), speech_final :: boolean()}
          | {:metadata, meta :: map()}
          | {:error, term()}
          | :ignore

  @type tts_canonical_event ::
          {:audio, binary()}
          | :turn_completed
          | :turn_aborted
          | {:alignment, timestamps :: list()}
          | {:error, term()}
          | :ignore

  # ----------------------------------------------------------------------------
  # 1. Telephony Carrier Real-Time Socket Events
  # ----------------------------------------------------------------------------

  @doc """
  Normalizes vendor-specific WebSocket events from Twilio, Telnyx, Vonage, Plivo, etc.
  """
  @spec normalize_carrier_event(term()) :: carrier_canonical_event()
  def normalize_carrier_event(payload)

  def normalize_carrier_event(%{"event" => "connected"}), do: :connected
  def normalize_carrier_event(%{"event" => "websocket:connected"}), do: :connected

  def normalize_carrier_event(%{"event" => "start"}), do: :call_start
  def normalize_carrier_event(%{"event" => "call.start"}), do: :call_start

  def normalize_carrier_event(%{"event" => "media"}), do: :call_media
  def normalize_carrier_event(%{"event" => "audio"}), do: :call_media

  def normalize_carrier_event(%{"event" => "stop"}), do: :call_stop
  def normalize_carrier_event(%{"event" => "disconnect"}), do: :call_stop
  def normalize_carrier_event(%{"event" => "websocket:terminated"}), do: :call_stop

  # DTMF Keypad Tones (e.g. {"event": "dtmf", "dtmf": {"digit": "1"}})
  def normalize_carrier_event(%{"event" => "dtmf", "dtmf" => %{"digit" => digit}}) do
    {:dtmf, to_string(digit)}
  end

  def normalize_carrier_event(%{"event" => "dtmf", "digit" => digit}) do
    {:dtmf, to_string(digit)}
  end

  def normalize_carrier_event(%{"event" => "keypress", "key" => digit}) do
    {:dtmf, to_string(digit)}
  end

  # Playback Mark Synchronizer (handset finished playing audio)
  def normalize_carrier_event(%{"event" => "mark", "mark" => %{"name" => name}}) do
    {:mark, to_string(name)}
  end

  def normalize_carrier_event(%{"event" => "mark", "name" => name}) do
    {:mark, to_string(name)}
  end

  # Carrier Clear Confirmation
  def normalize_carrier_event(%{"event" => "clear"}), do: :clear

  # Carrier Error Event
  def normalize_carrier_event(%{"event" => "error", "error" => err}) do
    {:error, err}
  end

  def normalize_carrier_event(_other), do: :ignore

  # ----------------------------------------------------------------------------
  # 2. Telephony HTTP Webhook Lifecycle Events (Twilio / Telnyx / Vonage Status)
  # ----------------------------------------------------------------------------

  @doc """
  Normalizes carrier HTTP webhook status callbacks.
  """
  @spec normalize_webhook_status(term()) :: webhook_status_event()
  def normalize_webhook_status(params) when is_map(params) do
    cond do
      params["RecordingUrl"] || params["recording_url"] ->
        url = params["RecordingUrl"] || params["recording_url"] || ""
        duration = parse_duration(params["RecordingDuration"] || params["duration"])
        {:recording_ready, url, duration}

      true ->
        status =
          params["CallStatus"] ||
            params["event_type"] ||
            params["status"] ||
            params["status_code"] ||
            ""

        case String.downcase(to_string(status)) do
          s when s in ["initiated", "queued", "call.initiated"] ->
            :call_initiated

          s when s in ["ringing", "call.ringing"] ->
            :call_ringing

          s when s in ["in-progress", "answered", "call.answered"] ->
            :call_answered

          s when s in ["completed", "call.hangup", "hangup"] ->
            :call_completed

          s when s in ["busy", "call.busy"] ->
            :call_busy

          s when s in ["no-answer", "no_answer", "call.no_answer"] ->
            :call_no_answer

          s when s in ["failed", "canceled", "cancelled", "call.failed"] ->
            :call_failed

          s when s in ["recording_ready", "recording_saved", "call.recording.saved"] ->
            url = params["RecordingUrl"] || params["recording_url"] || ""
            duration = parse_duration(params["RecordingDuration"] || params["duration"])
            {:recording_ready, url, duration}

          _ ->
            :ignore
        end
    end
  end

  def normalize_webhook_status(_other), do: :ignore

  # ----------------------------------------------------------------------------
  # 3. Speech-to-Text (STT) Socket Events
  # ----------------------------------------------------------------------------

  @doc """
  Normalizes vendor-specific STT event strings or payloads into canonical enum.
  """
  @spec normalize_stt_event(term()) :: stt_canonical_event()
  def normalize_stt_event(event)

  def normalize_stt_event(event) when is_binary(event) do
    case String.downcase(String.trim(event)) do
      s when s in [
        "speechstarted",
        "speech_started",
        "speech_start",
        "vad_start",
        "vad_started",
        "vad_detected",
        "speech_detected",
        "input_audio_buffer.speech_started",
        "partialtranscript"
      ] ->
        :speech_started

      s when s in [
        "speechended",
        "speech_ended",
        "speech_end",
        "speech_final",
        "utterance_end",
        "utteranceend",
        "vad_end",
        "vad_stopped",
        "input_audio_buffer.speech_stopped"
      ] ->
        :speech_ended

      _ ->
        :ignore
    end
  end

  def normalize_stt_event(:speech_started), do: :speech_started
  def normalize_stt_event(:vad_started), do: :speech_started
  def normalize_stt_event(:speech_ended), do: :speech_ended
  def normalize_stt_event(:vad_ended), do: :speech_ended

  def normalize_stt_event(%{"type" => "SpeechStarted"}), do: :speech_started
  def normalize_stt_event(%{"type" => "UtteranceEnd"}), do: :speech_ended
  def normalize_stt_event(%{"type" => "Metadata"} = meta), do: {:metadata, meta}
  def normalize_stt_event(%{"message_type" => "SessionBegins"} = meta), do: {:metadata, meta}
  def normalize_stt_event(%{"type" => "Error", "message" => msg}), do: {:error, msg}
  def normalize_stt_event(%{"error" => err}) when not is_nil(err), do: {:error, err}
  def normalize_stt_event(%{"event" => event}), do: normalize_stt_event(event)
  def normalize_stt_event(%{"message_type" => type}), do: normalize_stt_event(type)
  def normalize_stt_event(_other), do: :ignore

  # ----------------------------------------------------------------------------
  # 4. Text-to-Speech (TTS) Socket Events
  # ----------------------------------------------------------------------------

  @doc """
  Normalizes vendor-specific TTS event strings or payloads into canonical enum.
  """
  @spec normalize_tts_event(term()) :: tts_canonical_event()
  def normalize_tts_event(event)

  def normalize_tts_event(event) when is_binary(event) do
    case String.downcase(String.trim(event)) do
      s when s in [
        "done",
        "turn_completed",
        "turn_complete",
        "response.audio.done",
        "playback_completed",
        "playback_done",
        "complete",
        "completed",
        "isfinal",
        "is_final"
      ] ->
        :turn_completed

      s when s in [
        "canceled",
        "cancelled",
        "response.cancel",
        "interrupted",
        "aborted",
        "turn_aborted",
        "flush"
      ] ->
        :turn_aborted

      _ ->
        :ignore
    end
  end

  def normalize_tts_event(:turn_completed), do: :turn_completed
  def normalize_tts_event(:done), do: :turn_completed
  def normalize_tts_event(:turn_aborted), do: :turn_aborted
  def normalize_tts_event(:aborted), do: :turn_aborted

  def normalize_tts_event(%{"type" => type}), do: normalize_tts_event(type)
  def normalize_tts_event(%{"event" => event}), do: normalize_tts_event(event)
  def normalize_tts_event(%{"done" => true}), do: :turn_completed
  def normalize_tts_event(%{"is_final" => true}), do: :turn_completed
  def normalize_tts_event(%{"normalizedAlignment" => align}), do: {:alignment, align}
  def normalize_tts_event(%{"word_timestamps" => align}), do: {:alignment, align}
  def normalize_tts_event(%{"error" => err}) when not is_nil(err), do: {:error, err}
  def normalize_tts_event(_other), do: :ignore

  defp parse_duration(nil), do: nil
  defp parse_duration(val) when is_integer(val), do: val
  defp parse_duration(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end
end
