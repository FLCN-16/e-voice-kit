# ADR-0009: SIP Stack Selection & Room Adapter Integration

## Status
**ACCEPTED** (2026-11-20)

## Context
E-Voice-Kit needs to bridge PSTN/SIP carriers into WebRTC rooms. The existing prototype relies on basic string parsing and simple UDP sockets.

## Decision
1. **Decoupled Architecture:** Telephony SIP dialogs are isolated in `EVoiceKit.SIP.RoomAdapter`.
2. **SFU Integration:** The SIP adapter registers an `UpTrack` in `EVoiceKit.SFU.Router` with G.711 PCMU (payload type 0, 8 kHz clock rate) and consumes room audio as a subscriber DownTrack.
3. **Transaction Stack Evaluation:** In Phase 7, evaluate `ersip` (transaction primitives) versus custom dialog management against SIPp compliance tests.

## Consequences
- **Positive:** Enables inbound phone calls to seamlessly participate in multi-party WebRTC rooms without breaking existing carrier WebSockets.
