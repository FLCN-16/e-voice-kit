# Dynamic On-the-Go Reconfiguration

E-Voice-Kit allows hot-swapping STT/TTS providers, speech models, languages, and voice personas at any time **without dropping the live phone call**.

---

## 1. Per-Call Configuration at Ingress

Specify call-specific providers directly in your TwiML `<Parameter>` tags:
```xml
<Response>
  <Connect>
    <Stream url="wss://your-domain.com/media/twilio">
      <Parameter name="stt_provider" value="sarvam" />
      <Parameter name="tts_provider" value="sarvam" />
      <Parameter name="language" value="hi-IN" />
      <Parameter name="speaker" value="meera" />
    </Stream>
  </Connect>
</Response>
```

---

## 2. Mid-Call Hot-Swap via Brain Bridge

When an AI agent detects a language switch (e.g. caller asks to speak in Hindi or Spanish), the backend emits an in-band WebSocket event:

```json
{
  "event": "reconfigure",
  "stt_provider": "sarvam",
  "tts_provider": "sarvam",
  "language_code": "hi-IN",
  "speaker": "meera"
}
```

The call session terminates the active English STT/TTS clients and launches the new ones in **$< 50\text{ ms}$**. Telephony audio continues uninterrupted.

---

## 3. Mid-Call Hot-Swap via REST API

Call administrators or human supervisors can reconfigure active calls via HTTP:

```bash
curl -X POST http://localhost:4000/calls/call_stream_id/reconfigure \
  -H "Content-Type: application/json" \
  -d '{
    "tts_provider": "elevenlabs",
    "voice_id": "21m00Tcm4TlvDq8ikWAM",
    "stt_provider": "deepgram"
  }'
```

---

## 4. Programmatic Elixir API

```elixir
EVoiceKit.reconfigure_call("call_stream_id", %{
  "tts_provider" => "fishaudio",
  "model_id" => "s2.1-pro"
})
```
