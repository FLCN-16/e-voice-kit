# ADR-0003: Single Unified Plan PeerConnection per Participant

## Status
**ACCEPTED** (2026-11-20)

## Context
Section 5.4 of [ELIXIR_REALTIME_SERVER_PLAN.md](../ELIXIR_REALTIME_SERVER_PLAN.md) and Section 12 of [ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md](../ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md) evaluate WebRTC transport topology:
- LiveKit historically utilizes two separate PeerConnections per client: one dedicated publisher PeerConnection and one subscriber PeerConnection.
- Modern WebRTC implementations (standardized on Unified Plan, RFC 8829) support bidirectional media (multiple audio and video transceivers) across a single PeerConnection.
- Each PeerConnection incurs ICE gathering, DTLS handshake, socket pairs, and state overhead on both client and server.

## Decision
1. **Single Unified Plan PeerConnection in Native Mode:**
   - For the native E-Voice protocol, each participant establishes exactly one Unified Plan PeerConnection for both publishing and subscribing tracks.
   - Dynamic publication and subscription are handled via renegotiation using transceivers (`sendrecv`, `sendonly`, `recvonly`) with MID matching.
2. **Resource Efficiency:**
   - Halves the number of active ICE agent instances, DTLS handshakes, and UDP socket bindings per participant on the server.
   - Simplifies participant connection lifecycle and disconnect handling.
3. **Compatibility Mode Isolation:**
   - If and when LiveKit SDK wire compatibility is enabled via `EVoiceKit.Signaling.LiveKitAdapter`, the adapter will orchestrate separate publisher and subscriber PeerConnections for that specific client session, mapping them internally into the participant's unified UpTrack/DownTrack state.

## Consequences
- **Positive:** Substantially lower CPU, memory, and port utilization on media servers; faster connection setup times for browser and mobile clients.
- **Positive:** Standard W3C WebRTC compliant flow aligned with modern browser engines.
- **Negative:** Renegotiation must handle offer glare cleanly.
- **Mitigation:** The native signaling protocol will implement polite/impolite peer negotiation rules (RFC 8829 Section 4.1.8) to resolve glare deterministically.
