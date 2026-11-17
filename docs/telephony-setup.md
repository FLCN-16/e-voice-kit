# Telephony Setup Guide

VoiceGateway connects directly to enterprise phone carriers via WebSockets and SIP.

---

## 1. Twilio Voice Media Streams

### Webhook Configuration
1. Open the [Twilio Console](https://console.twilio.com/).
2. Navigate to **Phone Numbers** $\rightarrow$ **Active Numbers** $\rightarrow$ select your number.
3. Under **Voice & Fax**, set **A CALL COMES IN** to:
   * **Webhook:** `POST https://your-domain.com/twiml`

### What Happens:
When a phone call rings, VoiceGateway responds with TwiML:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Connect>
    <Stream url="wss://your-domain.com/media/twilio">
      <Parameter name="caller_number" value="+12125551234" />
      <Parameter name="dialed_number" value="+18005550199" />
    </Stream>
  </Connect>
</Response>
```
Twilio opens a bi-directional WebSocket streaming raw 8kHz G.711 μ-law audio to [`VoiceGateway.Transports.TwilioWebSocket`](file:///c:/Users/RishabhKumar/Work/openring-main/elixir/lib/voice_gateway/transports/twilio_websocket.ex).

---

## 2. Telnyx Media Streaming

### Portal Configuration
1. Log into the [Telnyx Portal](https://portal.telnyx.com/).
2. Create a Call Control Application or TeXML Application.
3. Point your media stream URL to:
   `wss://your-domain.com/media/telnyx`
4. Set bidirectional audio and codec to `PCMU` (G.711 μ-law).

---

## 3. Direct SIP / BYO-Trunk (RFC 3261)

For on-premises PBXs (Asterisk, FreeSWITCH, Cisco CUCM):
* **SIP Port:** `5060/udp`
* **RTP Port Range:** `40000–40999/udp`
* **Codec:** Static payload type `0` (PCMU) or `8` (PCMA).
