# Pluggable Carrier Transports & Base Class Guide

E-Voice-Kit provides an extensible, pluggable architecture for telephony carrier transports (Twilio, Telnyx, Vonage, Plivo, Bandwidth, and direct SIP/RTP trunks).

Instead of forcing developers to manage raw WebSocket handshakes, OTP supervision trees, and process monitors manually, E-Voice-Kit provides:
1. **`EVoiceKit.Providers.Carrier`**: The formal behaviour specification for all telephony providers.
2. **`EVoiceKit.Transports.WebSocketCarrier`**: The **abstract base class macro** that provides 100% of the `WebSock` protocol compliance, `Session` supervision, audio routing, barge-in buffer flushing, and process lifecycle handling out of the box.

---

## 1. Quick Tutorial: Implementing a New Carrier in 5 Minutes

To add support for any new carrier (for example, **Vonage**, **Plivo**, or a custom browser gateway), create a new file in `lib/e_voice_kit/transports/` and `use EVoiceKit.Transports.WebSocketCarrier`:

```elixir
defmodule EVoiceKit.Transports.VonageWebSocket do
  @moduledoc """
  WebSock carrier handler for Vonage Voice WebSockets.
  """

  use EVoiceKit.Transports.WebSocketCarrier

  # 1. Unique carrier identifier atom
  @impl EVoiceKit.Providers.Carrier
  def carrier_name, do: :vonage

  # 2. Extract call ID and session options on call start
  @impl EVoiceKit.Providers.Carrier
  def parse_start_event(%{"event" => "websocket:connected"} = msg, state) do
    call_id = msg["uuid"]

    session_opts = [
      call_id: call_id,
      caller_number: msg["from"],
      dialed_number: msg["to"],
      tenant_id: msg["tenant_id"],
      assistant_id: msg["assistant_id"],
      stt_provider: :deepgram,
      tts_provider: :elevenlabs
    ]

    {:ok, call_id, session_opts, state}
  end

  def parse_start_event(_other, _state), do: :ignore

  # 3. Decode inbound carrier audio into raw 8kHz G.711 μ-law bytes
  @impl EVoiceKit.Providers.Carrier
  def parse_media_event(%{"event" => "audio", "data" => base64_payload}, state) do
    case Base.decode64(base64_payload) do
      {:ok, mulaw_audio} -> {:ok, mulaw_audio, state}
      :error -> {:error, :invalid_base64}
    end
  end

  def parse_media_event(_other, _state), do: :ignore

  # 4. Encode outbound synthesized agent audio to the carrier wire format
  @impl EVoiceKit.Providers.Carrier
  def encode_media_frame(mulaw_chunk, state) do
    payload = %{
      "event" => "audio",
      "data" => Base.encode64(mulaw_chunk)
    }

    {:reply, {:text, Jason.encode!(payload)}, state}
  end

  # 5. Flush carrier playback queue on caller barge-in
  @impl EVoiceKit.Providers.Carrier
  def encode_clear_frame(_state) do
    payload = %{"event" => "clear"}
    {:reply, {:text, Jason.encode!(payload)}, _state}
  end
end
```

### What `use EVoiceKit.Transports.WebSocketCarrier` Handles Automatically:
* ✅ Implements all Bandit / Plug `WebSock` callbacks (`init/1`, `handle_in/2`, `handle_info/2`, `terminate/2`).
* ✅ Automatically starts and supervises the per-call `EVoiceKit.Pipeline.Session` GenServer using `SessionSupervisor.start_session/1`.
* ✅ Intercepts inbound caller audio and sends `{:caller_audio, mulaw_audio}` directly to the active session.
* ✅ Intercepts outbound agent speech (`{:send_audio, chunk}`) from the session and serializes it using your `encode_media_frame/2`.
* ✅ Detects inbound DTMF touch-tones (`{:dtmf, digit}`) and notifies the agent brain immediately.
* ✅ Sends and tracks playback synchronization marks (`encode_mark_frame/2`), confirming exactly when speech finishes playing on the caller's physical handset.
* ✅ Handles caller barge-in (`:clear_audio`), calling your `encode_clear_frame/1` to flush the carrier's playback queue.
* ✅ Manages call termination and carrier disconnects (`{:caller_hangup, reason}`).
* ✅ Allows overriding any callback with `defoverridable`.

---

## 2. Mounting Webhooks in `EVoiceKit.Endpoint`

Mount your WebSocket and HTTP webhook endpoints in `lib/e_voice_kit/endpoint.ex`:

```elixir
# Telephony Media Stream WebSocket
get "/media/vonage" do
  conn
  |> WebSockAdapter.upgrade(EVoiceKit.Transports.VonageWebSocket, [], timeout: :infinity)
  |> halt()
end

# Webhook Call Status Updates
post "/webhooks/vonage/events" do
  canonical_status = EVoiceKit.Providers.Events.normalize_webhook_status(conn.params)
  conn |> send_resp(200, Jason.encode!(%{"received" => true, "status" => to_string(canonical_status)}))
end
```

---

## 3. Direct SIP / RTP Trunks (`EVoiceKit.Transports.SIPCarrier`)

For direct BYO-Trunk SIP connections without Twilio or Telnyx:

* **Signaling (RFC 3261)**: Parsed and built by `EVoiceKit.Transports.SIP.Message`. Supports `INVITE`, `180 Ringing`, `200 OK`, `ACK`, `BYE`, and `REFER` (call transfers).
* **Media (RFC 3550)**: Native UDP packetization via `EVoiceKit.Transports.SIP.RTP`. Directly encodes and decodes 20ms G.711 μ-law / A-law audio datagrams without third-party PBX dependencies (no FreeSWITCH or Asterisk needed).
* **Carrier GenServer**: `EVoiceKit.Transports.SIPCarrier` implements `EVoiceKit.Providers.Carrier`, binding to an ephemeral UDP port and bridging the RTP stream directly to the call session.

---

## 4. Behaviour Reference (`EVoiceKit.Providers.Carrier`)

| Callback | Description | Default when using `WebSocketCarrier` |
| :--- | :--- | :--- |
| `carrier_name/0` | Returns carrier atom (`:twilio`, `:telnyx`, `:vonage`, etc.) | **Required** |
| `parse_start_event/2` | Extracts `call_id` and `session_opts` on setup | **Required** |
| `parse_media_event/2` | Extracts 8kHz μ-law bytes from inbound message | **Required** |
| `encode_media_frame/2` | Wraps μ-law chunk into carrier JSON / binary frame | **Required** |
| `encode_clear_frame/1` | Flushes playback queue on caller barge-in | Returns `:ignore` |
| `encode_mark_frame/2` | Synchronizes physical handset playback timing | Returns `:ignore` |
| `encode_hangup_frame/1` | Sends carrier disconnect frame | Closes socket with `{:stop, :normal, state}` |
| `encode_transfer_frame/2` | Executes carrier call transfer (e.g. SIP REFER) | Returns `:ignore` |
| `parse_stop_event/2` | Detects carrier hangup/stop event | Checks for `%{"event" => "stop"}` |
