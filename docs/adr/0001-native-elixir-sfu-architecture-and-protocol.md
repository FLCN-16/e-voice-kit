# ADR-0001: Native E-Voice Protocol & SFU Architecture Baseline

## Status
**ACCEPTED** (2026-11-20)

## Context
E-Voice-Kit needs to evolve from an AI telephony gateway into a native Elixir/BEAM real-time media communication server with capabilities comparable to LiveKit (WebRTC SFU, rooms, participants, tracks, DataChannels, SIP gateway, and AI participant integration). 

A key question raised in Section 2.3 of [ELIXIR_REALTIME_SERVER_PLAN.md](../ELIXIR_REALTIME_SERVER_PLAN.md) and Section 35 (Question 1) of [ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md](../ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md) is:
*Should we target a native E-Voice protocol as the primary implementation, or make unmodified LiveKit SDK wire compatibility a release-one requirement?*

## Decision
1. **Native E-Voice Protocol as Baseline:** We will design and implement the native E-Voice protocol as the core target for Release 1. The protocol features:
   - Versioned WebSocket signaling.
   - Application-envelope compression supporting Brotli, gzip, and Zstandard via directional capability negotiation.
   - Decoupled media plane using ExWebRTC (WebRTC SRTP/SRTCP over ICE/UDP) and keeping media strictly off the WebSocket signaling path.
   - Unified Plan PeerConnection model per participant.
2. **Decoupled SFU/Room Domain:** The internal room, participant, track, and SFU routing domain models will remain strictly agnostic of the wire protocol.
3. **LiveKit Wire Compatibility as Adapter:** Unmodified LiveKit SDK compatibility will be treated as a distinct protocol adapter mode (`EVoiceKit.Signaling.LiveKitAdapter`). It will only be certified once its Protobuf schema, connection semantics, and official SDK interoperability test suites are satisfied.
4. **Preservation of Existing Telephony & AI:** Existing Twilio, Telnyx, Vonage, and SIP telephony transports and AI providers (Deepgram, ElevenLabs, AssemblyAI, Cartesia, OpenAI, Anthropic) remain operational without regression during this evolution.

## Consequences
- **Positive:** Gives full freedom to optimize protocol design, negotiation, compression (Brotli/Zstd), and process boundaries in Elixir/OTP without being constrained by legacy wire quirks of another product.
- **Positive:** Dramatically reduces the surface area needed to achieve Milestone 1 (browser-to-browser Opus audio via Elixir SFU).
- **Negative:** Native browser and mobile SDKs or adapters must be provided for client applications to connect over the native protocol.
- **Mitigation:** The native protocol will provide a lightweight JavaScript/TypeScript SDK, followed by the LiveKit compatibility adapter in subsequent phases.
