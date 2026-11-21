# Architecture Decision Records (ADRs)

This directory documents the key architectural decisions for E-Voice-Kit's native Elixir real-time SFU media server, as mandated in [ELIXIR_REALTIME_SERVER_PLAN.md](../ELIXIR_REALTIME_SERVER_PLAN.md) (Section 18) and [ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md](../ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md) (Section 35).

## Status Legend
- **PROPOSED**: Under active evaluation/discussion
- **ACCEPTED**: Approved architectural baseline for implementation
- **SUPERSEDED**: Replaced by a subsequent ADR
- **DEFERRED**: Pending further benchmark/spike gates

---

## Decision Register

| ADR | Title | Status | Date | Summary |
|---|---|---|---|---|
| [ADR-0001](0001-native-elixir-sfu-architecture-and-protocol.md) | Native E-Voice Protocol & SFU Architecture Baseline | **ACCEPTED** | 2026-11-20 | Adopt native E-Voice protocol as release-one target; isolate LiveKit wire compatibility to an adapter layer |
| [ADR-0002](0002-compression-binary-envelope-and-negotiation.md) | 28-Byte Binary Envelope & Directional Compression Negotiation | **ACCEPTED** | 2026-11-20 | Define fixed 28-byte `EVK1` header; negotiate NONE/GZIP/BROTLI/ZSTD per direction; keep media off signaling |
| [ADR-0003](0003-unified-plan-webrtc-topology.md) | Single Unified Plan PeerConnection per Participant | **ACCEPTED** | 2026-11-20 | Use single Unified Plan PeerConnection per participant in native mode; defer dual-PC to LiveKit adapter |
| [ADR-0004](0004-signaling-encoding-and-bootstrap.md) | Signaling Encoding & Bootstrap Handshake | **ACCEPTED** | 2026-11-20 | ClientHello/ServerHello uncompressed handshake; EVK1 payload framing |
| [ADR-0005](0005-compression-traffic-class-profiles.md) | Directional Algorithm Selection vs Traffic-Class Profiles | **ACCEPTED** | 2026-11-20 | Directional baseline in V1; threshold bypass for small payloads |
| [ADR-0006](0006-browser-compression-detection-and-wasm.md) | Browser Compression Probing & Fallback Strategy | **ACCEPTED** | 2026-11-20 | Native MDN CompressionStream capability probing; require NONE baseline |
| [ADR-0007](0007-exsctp-datachannel-build-strategy.md) | ExSCTP Dependency & Native Rust Toolchain Strategy | **ACCEPTED** | 2026-11-20 | Make DataChannels optional in mix.exs; containerize Rust build toolchain |
| [ADR-0008](0008-track-forwarder-ownership-and-concurrency.md) | Track & Packet-Forwarder Process Ownership | **ACCEPTED** | 2026-11-20 | Isolate PeerConnectionOwner from RoomCoordinator; asynchronous packet forwarding |
| [ADR-0009](0009-sip-stack-selection-and-integration.md) | SIP Stack Selection: Framework vs Primitive vs Custom | **ACCEPTED** | 2026-11-20 | Isolate SIP call legs via RoomAdapter; bridge PCMU audio into SFU Router |
| [ADR-0010](0010-video-codec-roadmap-and-licensing.md) | Video Codec Roadmap & H.264 Licensing Boundaries | **ACCEPTED** | 2026-11-20 | VP8 baseline and H.264 pass-through; avoid expensive video transcoding |
| [ADR-0011](0011-recording-storage-and-retention.md) | Recording Architecture, Storage & Retention Security | **ACCEPTED** | 2026-11-20 | Supervised recording consumer decoupled from forwarding fast-path |
| [ADR-0012](0012-multi-node-cluster-and-redis-coordination.md) | Multi-Node Room Placement & Redis Coordination Model | **ACCEPTED** | 2026-11-20 | Single-node authoritative room owner in Phase 1-6; Redis for cluster leases |
| [ADR-0013](0013-tenant-quotas-and-abuse-controls.md) | Tenant Resource Quotas, Rate Limiting & Abuse Defense | **ACCEPTED** | 2026-11-20 | Strict quotas on participants, tracks, payload sizes, and decompression bombs |
| [ADR-0014](0014-compression-thresholds-and-scheduler-policy.md) | Compression Thresholds, Levels & BEAM Scheduler Budgets | **ACCEPTED** | 2026-11-20 | 256 B compression threshold; stateless operations; dirty scheduler NIFs |
