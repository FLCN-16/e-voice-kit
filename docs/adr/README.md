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
| [ADR-0004](0004-signaling-encoding-and-bootstrap.md) | Signaling Encoding & Bootstrap Handshake | **PROPOSED** | 2026-11-20 | ClientHello/ServerHello uncompressed handshake; Protobuf payload encoding with strict versioning |
| [ADR-0005](0005-compression-traffic-class-profiles.md) | Directional Algorithm Selection vs Traffic-Class Profiles | **PROPOSED** | 2026-11-20 | Directional baseline in V1; evaluate traffic-class profiles (control vs bulk) following benchmarks |
| [ADR-0006](0006-browser-compression-detection-and-wasm.md) | Browser Compression Probing & Fallback Strategy | **PROPOSED** | 2026-11-20 | Native MDN CompressionStream capability probing; require NONE baseline; defer WASM fallbacks |
| [ADR-0007](0007-exsctp-datachannel-build-strategy.md) | ExSCTP Dependency & Native Rust Toolchain Strategy | **PROPOSED** | 2026-11-20 | Make DataChannels optional in Phase 0; containerize Rust toolchain for ExSCTP compilation |
| [ADR-0008](0008-track-forwarder-ownership-and-concurrency.md) | Track & Packet-Forwarder Process Ownership | **PROPOSED** | 2026-11-20 | Isolate PeerConnectionOwner from RoomCoordinator; asynchronous packet forwarding without GenServer serialization |
| [ADR-0009](0009-sip-stack-selection-and-integration.md) | SIP Stack Selection: Framework vs Primitive vs Custom | **PROPOSED** | 2026-11-20 | Gate SIP stack choice on RFC 3261 compliance and load tests (NkSIP vs ersip vs custom dialog engine) |
| [ADR-0010](0010-video-codec-roadmap-and-licensing.md) | Video Codec Roadmap & H.264 Licensing Boundaries | **PROPOSED** | 2026-11-20 | Target VP8 and H.264 pass-through first; assess distribution licensing and hardware acceleration constraints |
| [ADR-0011](0011-recording-storage-and-retention.md) | Recording Architecture, Storage & Retention Security | **PROPOSED** | 2026-11-20 | Supervised recording consumer decoupled from forwarding fast-path; encrypted storage and strict tenant retention |
| [ADR-0012](0012-multi-node-cluster-and-redis-coordination.md) | Multi-Node Room Placement & Redis Coordination Model | **PROPOSED** | 2026-11-20 | Single-node authoritative room owner in Phase 1-6; Redis for distributed cluster metadata/leases in Phase 8 |
| [ADR-0013](0013-tenant-quotas-and-abuse-controls.md) | Tenant Resource Quotas, Rate Limiting & Abuse Defense | **PROPOSED** | 2026-11-20 | Strict limits on participants, tracks, SDP renegotiation, payload sizes, and decompression bombs |
| [ADR-0014](0014-compression-thresholds-and-scheduler-policy.md) | Compression Thresholds, Levels & BEAM Scheduler Budgets | **PROPOSED** | 2026-11-20 | Minimum payload compression threshold (512 B); bounded decompression memory/reductions; dirty scheduler pool |
