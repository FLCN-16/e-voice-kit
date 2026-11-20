# E-Voice-Kit: Native Elixir Real-Time Media Server Plan

> Status: Research-backed implementation plan — awaiting architecture decisions  
> Prepared: 2026-11-20  
> Repository baseline: develop branch  
> Scope: Documentation only. This plan does not change runtime code or dependencies.

## 1. Executive summary

The objective is to evolve E-Voice-Kit from a real-time Voice AI and telephony gateway into a native Elixir/BEAM real-time communication server with capabilities comparable to the core of LiveKit:

- WebRTC connection establishment and secure media transport.
- Signaling, rooms, participants, tracks, permissions and subscriptions.
- Selective Forwarding Unit (SFU) routing for audio and video.
- RTP/RTCP feedback, retransmission and congestion-aware forwarding.
- WebRTC DataChannels.
- SIP/PSTN gateway integration.
- Browser, mobile, SIP and AI-agent participants.
- Recording, observability, multi-tenancy and eventually distributed media nodes.
- Negotiated application-message compression using Brotli, gzip and Zstandard, selected according to capabilities advertised by each client.

The recommended technical starting point is ExWebRTC, subject to a proof of concept against the exact release and APIs. ExWebRTC implements the WebRTC API in Elixir and builds on separate ICE, DTLS, SRTP, RTP, RTCP and SDP components. It does not provide a complete LiveKit-style SFU or room server: those application and routing layers remain our responsibility.

The project must preserve its current AI-provider and carrier capabilities, but media transport, call/agent orchestration, and room/participant state must become separate domains.

### Recommended architectural principle

**Use Elixir/OTP for control, lifecycle, ownership, routing policy and media coordination; use ExWebRTC and its compatible protocol components for WebRTC primitives; keep RTP media off the signaling WebSocket.**

The first end-to-end milestone is deliberately narrow:

> Two browser clients join one room through the Elixir server. Browser A publishes microphone audio. The server receives the WebRTC RTP stream and forwards it to Browser B. Browser B plays the audio. No LiveKit server or other SFU is involved.

No capacity, latency or production-readiness claim should be made until this vertical slice and its load tests are measured.

---

## 2. Product scope, goals and non-goals

### 2.1 Goals

1. Implement an SFU-oriented real-time media server in Elixir.
2. Provide a versioned signaling protocol with room, participant, track and subscription operations.
3. Support WebRTC audio and video transport, secure by default.
4. Support browser and mobile WebRTC clients and a SIP gateway.
5. Represent AI agents as first-class room participants that can subscribe to audio and publish generated audio.
6. Negotiate capabilities on every new signaling connection.
7. Select compression separately for each direction from the algorithms actually supported by both endpoints.
8. Bound memory, CPU, queues, packet rates, message sizes and decompression work.
9. Preserve the existing Twilio, Telnyx, Vonage, SIP and pluggable AI provider functionality through adapters.
10. Establish a test and observability system that can detect interoperability failures and edge cases.

### 2.2 Non-goals for the first release

- Reimplement ICE, DTLS, SRTP, SCTP, codecs or cryptographic primitives from scratch.
- Decode and re-encode every media packet in the SFU forwarding path.
- Build a global multi-region media mesh before a stable single-node SFU exists.
- Make SIP signaling, SIP registration, PSTN routing and WebRTC SFU launch as one inseparable milestone.
- Apply Brotli, gzip or Zstandard to RTP/SRTP media packets or encoded Opus/video payloads.
- Claim LiveKit SDK compatibility unless the LiveKit wire protocol and interoperability suites are implemented.
- Promise a specific concurrent participant count before representative benchmarks.

### 2.3 Product modes to keep explicit

The architecture should separate these two possible protocol products:

| Mode | Description | Compatibility impact |
|---|---|---|
| Native E-Voice protocol | A versioned protocol designed for this server, including Brotli/gzip/Zstd capability negotiation | Requires our own browser/mobile SDKs or client adapters |
| LiveKit-compatible protocol | Implements the relevant LiveKit signaling messages, semantics, connection behavior and compression behavior | Existing LiveKit SDKs may connect only after protocol-level interoperability is demonstrated |

**Recommendation:** keep the internal room/participant/track/SFU model independent of either wire protocol. Implement the native protocol for the first vertical slice unless the project owner explicitly makes unmodified LiveKit SDK compatibility a release-one requirement. Add a compatibility protocol adapter as a separately tested mode.

This is an unresolved architecture decision and must not be silently treated as settled.

---

## 3. Current repository audit

The following assessment is based on the code and documentation in the develop branch as inspected on 2026-11-20.

### 3.1 Current project baseline

- The project is an Elixir application currently declaring Elixir ~> 1.15.
- The application uses Bandit, WebSockAdapter, Finch, Jason, Msgpax, WebSockex, Telemetry and CorsPlug.
- ExWebRTC is not currently a dependency.
- The supervision tree currently includes the session Registry, Finch, Task.Supervisor, the call Session DynamicSupervisor and Bandit.
- Docker Compose currently defines E-Voice-Kit and PostgreSQL. It does not define a LiveKit-compatible SFU, Redis or Coturn.
- Existing Pipeline.Session assumes a transport process and uses telephony-oriented μ-law audio messages.
- Existing audio buffering is based on 160-byte / 20 ms G.711 μ-law frames.
- Existing carrier behaviour describes media as 8 kHz G.711 μ-law bytes.
- Existing endpoint routes cover health, Twilio/Telnyx/Vonage media WebSockets, TwiML and carrier webhooks. There is no implemented native WebRTC room/signaling endpoint in the inspected router.
- The README describes a browser media URL and ephemeral JWT use, but the inspected router does not implement that browser route. This discrepancy must be resolved rather than assumed to be working.
- The global endpoint currently configures wildcard CORS. Browser signaling requires a deliberate Origin and authentication policy; WebSocket Origin validation is a separate concern and must also be addressed.
- The SIP code has a basic RTP packet helper and a simple SIP message / SDP parser. It does not yet constitute a complete SIP transaction/dialog implementation or production SIP stack.
- Docker Compose contains development credentials for PostgreSQL. Production deployment must require explicit secrets and must not reuse these defaults.

### 3.2 Existing modules to preserve or refactor

| Current module | Proposed treatment |
|---|---|
| EVoiceKit.LLM.Agent | Preserve as an AI-agent implementation |
| EVoiceKit.Clients.STTStreamer and provider clients | Preserve; add media-format adapters |
| EVoiceKit.Clients.TTSStreamer and provider clients | Preserve; add room-track publishing adapter |
| EVoiceKit.Clients.BrainBridge | Preserve as an optional external agent bridge |
| EVoiceKit.Codec.G711 | Preserve for PCMU/PCMA telephony |
| EVoiceKit.Pipeline.Session | Refactor into a logical AI/agent session, independent of a particular carrier or PeerConnection |
| EVoiceKit.Pipeline.Buffer | Generalize; keep a telephony-specific 160-byte packetizer where needed |
| EVoiceKit.Providers.Carrier | Retain as the existing carrier contract; do not overload it as the SFU transport contract |
| EVoiceKit.Transports.WebSocketCarrier | Retain for carrier-specific Twilio/Telnyx/Vonage protocols |
| EVoiceKit.Transports.SIPCarrier | Treat as a prototype; replace or substantially rework for complete SIP behavior |
| EVoiceKit.Endpoint | Extend with versioned signaling, room APIs and authenticated connection/bootstrap routes |
| EVoiceKit.Application | Add room, peer-connection, track-routing and compression supervision |

### 3.3 Migration rule

Do not rewrite the existing AI/telephony path as part of the first SFU milestone. Introduce new room/WebRTC domains alongside the existing carrier implementation. Migrate the AI session interface to media-independent frames only when compatibility tests prove that Twilio/Telnyx/Vonage continue to work.

---

## 4. Research-backed technology choices

### 4.1 ExWebRTC is the leading candidate

Candidate: ExWebRTC 0.18.0, released on Hex on 2026-10-26.

ExWebRTC implements the W3C WebRTC API. Its dependency list for this release includes:

- ex_dtls
- ex_ice
- ex_libsrtp
- ex_rtcp
- ex_rtp
- ex_sdp
- qex
- optional ex_sctp for DataChannels

The ex_sctp dependency is optional. The ExWebRTC PeerConnection source explains that DataChannel support is disabled when the optional dependency is not installed, and that its build requires Rust.

The ExWebRTC 0.17 documentation exposes relevant APIs/events such as incoming RTP and RTCP events, send_rtp, send_pli, ICE candidate addition, SDP descriptions, transceivers and DataChannel operations. The implementation plan must validate those details against the exact 0.18.0 source before relying on a particular API or callback signature.

**Phase 0 gate:** compile and run a small server/browser proof of concept with the exact dependency lockfile, test supported codec/SDP combinations, receive RTP, send RTP, and establish a DataChannel. Confirm all native build requirements in CI and the production container.

References:
- https://hex.pm/packages/ex_webrtc/0.18.0
- https://hex.pm/packages/ex_webrtc/0.18.0/dependencies
- https://hexdocs.pm/ex_webrtc/0.18.0/
- https://github.com/elixir-webrtc/ex_webrtc
- https://hex.pm/packages/ex_sctp

### 4.2 Membrane

Membrane is a candidate for media processing tasks such as audio decoding, conversion, recording, playback and transcoding. It should not be inserted into every packet-forwarding path merely because it exists.

The old membrane_rtc_engine project is archived. It remains a useful source of architectural patterns and test cases, but should not be adopted as an unmaintained turnkey SFU foundation.

The Membrane WebRTC plugin and all media plugins must be checked for exact compatibility with the selected ExWebRTC version before they are added.

References:
- https://github.com/membraneframework
- https://github.com/membraneframework/membrane_webrtc_plugin
- https://github.com/fishjam-cloud/membrane_rtc_engine

### 4.3 TURN and STUN

Use an established TURN server such as Coturn for the initial deployment rather than attempting to implement a production TURN service in the first milestone.

Deployment should support:
- STUN discovery.
- TURN over UDP.
- TURN over TCP.
- TURN over TLS where required by restrictive networks.
- Short-lived authenticated credentials.
- IPv4 and IPv6.
- A configured relay port range.
- Relay-only integration tests.

Reference: https://github.com/coturn/coturn

### 4.4 SIP research candidates

The existing SIP implementation should not be expanded into a production implementation by adding more regular expressions and response strings.

Research these Erlang ecosystem options before selecting a SIP foundation:

- NkSIP: a full Erlang SIP application-server framework with multiple SIP transports, dialog and service concepts. Verify current maintenance, supported OTP/Elixir versions, security posture and release status.
  - https://github.com/erlnets/nksip
- ersip: a lower-level SIP/SDP and transaction primitive library. It intentionally does not provide a server/supervision framework.
  - https://github.com/poroh/ersip
- Parrot / parrot_platform: an Elixir telecom project whose published alpha notes describe SIP, RTP and Membrane integration. Its published notes list important limitations, including no TLS/TCP at that time and limited codecs. Treat it as experimental until current support is demonstrated.
  - https://github.com/byoungdale/parrot
  - https://hex.pm/packages/parrot_platform

**Decision gate:** compare these candidates using the exact SIP methods, transports, transaction semantics, SDP negotiation, security requirements and load tests required by E-Voice-Kit. Do not select one based only on its README feature list.

---

## 5. Target architecture

### 5.1 Logical layers

1. **Client layer:** browser, iOS, Android, React Native, Flutter, SIP endpoint and AI-agent participant.
2. **Edge/API layer:** HTTPS APIs, WebSocket signaling, authentication, rate limiting and connection bootstrap.
3. **Signaling/control plane:** protocol negotiation, room/participant lifecycle, permissions, SDP/ICE signaling, publish/unpublish and subscription requests.
4. **WebRTC transport plane:** PeerConnection, ICE, DTLS, SRTP/SRTCP, SCTP and DataChannels.
5. **SFU plane:** track registry, publisher ingress, subscriber egress, routing, RTCP feedback, retransmission, congestion control and simulcast/SVC layer choice.
6. **Media services:** optional audio decode, VAD, recording, playback, transcoding and media inspection.
7. **Voice AI plane:** STT, LLM, TTS, agent session and tools.
8. **Telephony plane:** SIP signaling, SIP dialogs, RTP media, DTMF, carrier adapters and PSTN routing.
9. **Distributed control plane:** room placement, node health, cluster membership, coordination and graceful draining.
10. **Observability/security plane:** telemetry, structured events, metrics, traces, audit records and resource-abuse controls.

### 5.2 Process ownership and OTP supervision

The initial single-node architecture should use supervisors and process boundaries with explicit ownership.

Suggested logical tree:

~~~text
EVoiceKit.Application
├── EVoiceKit.ConnectionRegistry
├── EVoiceKit.RoomRegistry
├── EVoiceKit.RoomDynamicSupervisor
│   └── EVoiceKit.RoomSupervisor (one per room)
│       ├── EVoiceKit.RoomCoordinator
│       ├── EVoiceKit.ParticipantDynamicSupervisor
│       │   └── EVoiceKit.ParticipantSession (one per participant)
│       │       ├── EVoiceKit.SignalingSession
│       │       └── EVoiceKit.PeerConnectionOwner (one per PeerConnection)
│       ├── EVoiceKit.TrackRegistry
│       └── EVoiceKit.SubscriptionManager
├── EVoiceKit.MediaSupervisor
│   ├── EVoiceKit.ForwarderSupervisor
│   ├── EVoiceKit.RetransmissionSupervisor
│   └── EVoiceKit.MediaWorkerPool
├── EVoiceKit.CompressionSupervisor
├── EVoiceKit.SIPSupervisor
├── EVoiceKit.AgentSessionSupervisor
├── EVoiceKit.TaskSupervisor
├── Finch
└── Bandit
~~~

This tree is conceptual. Exact process boundaries should follow the ExWebRTC ownership model discovered during Phase 0.

**Critical performance rule:** the RoomCoordinator is a control-plane owner. It must not receive a synchronous GenServer call for every RTP packet and must not serialize the media path. Track routing must have a bounded, low-latency path with bounded mailboxes/queues and explicit overload behavior.

Each PeerConnection, ParticipantSession, room and agent session needs a clear owner, monitor/link strategy, restart policy and cleanup contract. A participant disconnect must remove its tracks and subscriptions without crashing unrelated participants in the room.

### 5.3 Core entities

| Entity | Responsibilities |
|---|---|
| Room | Lifecycle, limits, metadata, participant ownership and policy |
| Participant | Identity, tenant, permissions, attributes, connection state and published tracks |
| PeerConnection | A negotiated WebRTC transport endpoint; a participant may own one or more |
| Track | Kind, codec, MID, RID, SSRC, clock rate, payload type, source and publication state |
| Subscription | Subscriber-to-track relationship, selected quality/layer and forwarding state |
| UpTrack | Publisher-side track identity and incoming media state |
| DownTrack | Subscriber-side track mapping and outgoing media state |
| AgentSession | Conversational state, STT/LLM/TTS lifecycle and tools |
| SIP Dialog / Call Leg | SIP transaction/dialog state and associated media endpoint |
| RoomNodeAssignment | Which media node owns the room in a multi-node deployment |

Do not conflate a participant, a PeerConnection, a track and an AI session. They have different lifecycles and cardinalities.

### 5.4 PeerConnection topology

The native protocol should initially select the simplest topology supported by the browser SDK and the ExWebRTC proof of concept. A single Unified Plan PeerConnection per participant may be sufficient for the first native client.

Do not assume this topology is wire-compatible with LiveKit. LiveKit documents a signaling/client protocol where a client may establish separate publisher and subscriber PeerConnections. If LiveKit compatibility is approved, implement and test the required topology in the compatibility adapter.

Record the choice in an ADR after the proof of concept.

---

## 6. Signaling protocol and connection lifecycle

### 6.1 Protocol requirements

- Versioned protocol with a defined minimum and maximum supported version.
- Binary Protobuf messages as the preferred native signaling encoding, subject to schema/tooling validation.
- Explicit request IDs for request/response correlation.
- Async event messages that do not require an immediate response.
- Idempotency rules for retries.
- Strict message-size and rate limits.
- Unknown-field behavior and forward/backward compatibility rules.
- Authentication before joining a room.
- Explicit room/participant permission grants.
- Timeouts and state transitions for every negotiation phase.
- A documented reconnect and ICE restart procedure.

### 6.2 Connection state machine

~~~text
HTTP_UPGRADE
    |
    v
AWAIT_CLIENT_HELLO
    | valid hello
    v
NEGOTIATING_CAPABILITIES
    | server hello accepted / handshake completed
    v
AUTHENTICATING
    | valid short-lived join credential
    v
JOINING_ROOM
    | room and participant allocated
    v
SIGNALING_READY
    | SDP / ICE negotiation
    v
PEER_CONNECTION_CONNECTING
    | ICE + DTLS + media transport established
    v
CONNECTED
    | reconnect / ICE restart / close / timeout
    v
RECOVERING or CLOSING
    |
    v
CLOSED
~~~

A state transition must be validated against the current state. Duplicate or out-of-order messages should be idempotently handled or rejected with a structured protocol error. They must not crash the process.

### 6.3 WebSocket signaling versus media

- The WebSocket carries signaling and application control messages.
- WebRTC transports media using SRTP/SRTCP.
- WebRTC DataChannels use SCTP over DTLS over ICE.
- RTP/SRTP audio and video packets must not be tunneled through the signaling WebSocket as the normal media path.
- Do not confuse a WebSocket binary frame with an RTP packet.
- SIP/RTP gateway media is a separate transport adapter into the room/track model.

The WebRTC transport profile requires secure RTP media and DTLS-based key establishment. DataChannels use SCTP over DTLS over ICE. See RFC 8835 and RFC 8827.

References:
- https://www.rfc-editor.org/rfc/rfc8835
- https://www.rfc-editor.org/rfc/rfc8827
- https://docs.livekit.io/reference/internals/client-protocol/

---

## 7. Compression capability negotiation

This is a required part of the native protocol, not an optional optimization.

### 7.1 Protocol distinction

There are three separate mechanisms, and they must not be conflated:

1. **HTTP response compression:** negotiate using HTTP Accept-Encoding / Content-Encoding.
2. **WebSocket per-message compression:** the standardized extension is permessage-deflate (RFC 7692). Do not advertise Brotli or Zstandard as if they were already standardized WebSocket extensions.
3. **Native E-Voice application-envelope compression:** our protocol can negotiate Brotli, gzip and Zstandard at the application layer and place the selected algorithm in our own binary message envelope.

For the native protocol, use mechanism 3. The WebSocket frames themselves can remain binary. Do not enable a second compression layer for messages that already use our envelope.

For LiveKit compatibility, follow LiveKit's actual wire behavior. Its current protocol defines GZIP for its wrapped join request and a separate DEFLATE_RAW capability for data streams. Do not silently substitute Brotli/Zstd into the official protocol.

References:
- https://www.rfc-editor.org/rfc/rfc7692
- https://github.com/livekit/protocol/blob/main/protobufs/livekit_rtc.proto
- https://github.com/livekit/protocol/blob/main/protobufs/livekit_models.proto

### 7.2 Bootstrap handshake

The first application message on every new signaling connection must be an uncompressed ClientHello. The server response must also be uncompressed. Compression is not active until both sides complete negotiation.

ClientHello should advertise:

- Minimum and maximum signaling protocol version.
- Client SDK name/version/platform.
- Supported encoders (algorithms the client can use to compress outbound messages).
- Supported decoders (algorithms the client can use to decompress inbound messages).
- none as the mandatory baseline.
- Maximum supported wire message size.
- Maximum supported decompressed size.
- Optional compression levels or profiles supported by the client.
- DataChannel capability and supported message profiles.
- WebRTC feature capabilities such as simulcast, SVC, codec list, header extensions and reconnect behavior.

ServerHello should advertise:

- Selected signaling protocol version.
- Server supported encoders and decoders.
- Selected client-to-server algorithm.
- Selected server-to-client algorithm.
- Optional per-traffic-class selections if the client and server support them.
- Maximum wire and decompressed sizes.
- Compression threshold/profile.
- No-context-takeover requirement.
- Selected WebRTC features and limits.
- A unique connection/session negotiation identifier.

The client must not assume that encode and decode capabilities are symmetric. The directional intersection is:

- Client-to-server: client encoders ∩ server decoders.
- Server-to-client: server encoders ∩ client decoders.

The server selects the preferred algorithm from the valid intersection according to a versioned policy. If no compressed algorithm is shared, select none.

The negotiation must be bound to the authenticated connection and must not be reusable across independent connections.

### 7.3 Algorithm IDs and initial policy

Reserve stable identifiers in the native envelope:

| ID | Algorithm | Wire format |
|---:|---|---|
| 0 | NONE | Uncompressed bytes |
| 1 | GZIP | RFC 1952 gzip stream |
| 2 | BROTLI | Brotli stream |
| 3 | ZSTD | Zstandard frame |

Do not use a raw DEFLATE stream under the gzip identifier. Do not confuse zlib-wrapped DEFLATE, raw DEFLATE, gzip and Zstandard framing.

Initial preference is a benchmark hypothesis, not a permanent rule:

- Zstandard is the first candidate for interactive signaling/application data because of its speed/ratio tradeoff.
- Brotli is a candidate for larger text-like or repetitive payloads where the improved ratio justifies CPU/latency.
- gzip is the compatibility fallback.
- none is always available and should be used when compression is unsupported, too expensive or ineffective.

The final policy must be established with realistic benchmarks for each traffic class and supported client runtime.

### 7.4 Envelope

Every compressed application message must identify enough metadata to be decoded safely and unambiguously. The envelope should contain:

- Envelope magic and version.
- Message type and flags.
- Compression algorithm ID (or explicit NONE).
- Payload length on the wire.
- Declared uncompressed length.
- Optional request/correlation ID.
- Payload bytes.
- Optional checksum only where the selected format or protocol requires it; transport security must not be confused with a checksum.

Lengths must be validated before decompression. The protocol must reject malformed, inconsistent or unsupported envelopes.

The exact binary layout and Protobuf schema are a Phase 0/1 ADR. Do not implement undocumented magic offsets or implicit assumptions in client code.

### 7.5 Directionality and message policy

- Negotiation is per connection and per direction.
- Use an independent compression operation per message in V1 (no context takeover).
- Allow individual messages to opt out of compression.
- Apply a minimum payload threshold, determined by benchmarks.
- If compression expands the payload or costs more than it saves, send uncompressed.
- Consider distinct profiles for interactive control messages and bulk application data only after measuring the benefits.
- A compression algorithm change requires a negotiated protocol update/reconnect; do not change it silently mid-stream.
- The receiver validates algorithm ID, negotiated state, payload length, output length and configured resource budgets.
- A compressed message before negotiation is a protocol error.

### 7.6 Browser capability detection

Browser clients must feature-detect the compression and decompression APIs independently. A client must not infer support solely from browser name/version or user-agent string.

Where available, the Compression Streams API exposes formats including Brotli, gzip, deflate, deflate-raw and Zstandard. Runtime support varies, so use actual constructor capability checks and a successful local round-trip test before advertising an algorithm.

Native clients should advertise only algorithms actually implemented and tested by their binary.

Reference: https://developer.mozilla.org/en-US/docs/Web/API/CompressionStream/CompressionStream

### 7.7 HTTP compression

HTTP APIs should independently support negotiated response compression using standard HTTP headers. This does not replace the signaling handshake and should not reuse WebSocket envelope state.

HTTP caches must vary responses on Accept-Encoding where applicable. Authenticated responses must not leak through shared caches.

### 7.8 DataChannel compression

If application payload compression is used over DataChannels:

- Reuse the negotiated capability vocabulary, but apply it only after the DataChannel is established.
- Use the same explicit per-message envelope or a versioned DataChannel-specific envelope.
- Enforce negotiated and per-channel maximum message sizes.
- Respect reliable/unreliable delivery and ordering policy.
- Avoid compressing tiny real-time events.
- Do not confuse WebRTC DataChannel compression with WebSocket permessage-deflate.
- Do not general-purpose compress RTP media packets.

### 7.9 Do not compress media packets

Do not run Brotli/gzip/Zstd over:

- RTP or SRTP packets.
- RTCP or SRTCP packets.
- Opus payloads.
- VP8/VP9/H.264 payloads.
- Other already compressed media or blob formats.

Media codecs and transport security already provide their own encoding and packetization. A second general-purpose compression layer adds work and latency and can break media semantics.

For media processing, decode only where a feature needs decoded content (for example an AI STT consumer or recording/transcoding pipeline). Keep the SFU forwarding path encoded whenever possible.

### 7.10 Compression security and failure handling

The implementation must include:

- Maximum compressed/wire bytes.
- Maximum decompressed bytes.
- Maximum expansion ratio.
- Maximum decompression CPU/time budget.
- Per-connection and global concurrent decompression limits.
- Bounded worker queues and rejection behavior under saturation.
- No unbounded output allocation based on untrusted advertised lengths.
- Validation of declared size against actual output.
- Truncated/corrupt stream handling.
- Unknown algorithm and algorithm mismatch handling.
- Rate limiting and abuse telemetry.
- No context takeover in V1.
- No compression of authentication tokens, secrets or sensitive values mixed with attacker-controlled text.
- No compression dictionaries supplied by untrusted clients in V1.
- Fuzzing for malformed frames and all decompressor APIs.
- Native-library crash isolation assessment.

Security findings observed during this research:

- The Erlang brotli package advisory EEF-CVE-2026-111497 reports an out-of-bounds write in the decoder in versions >=0.3.0 and <0.3.4. The package page lists 0.3.4 as the fixed release. Do not use affected versions.
- The ezstd package advisory CVE-2026-119434 reports a decompression-bomb / unbounded-output issue in decompress_using_ddict/2 for versions >=1.0.5 and <1.2.5. The package page lists 1.2.5 as the fixed release. Do not use affected versions; prefer a bounded decompression API and prove the output limit in tests.
- OTP's :zlib provides deflate/gzip/zlib facilities, but the exact framing mode and resource behavior must be explicitly tested.

Minimum research baseline as of 2026-11-20:
- brotli >= 0.3.4, subject to ongoing advisory review.
- ezstd >= 1.2.5, subject to ongoing advisory review.
- Gzip through OTP :zlib initially, subject to API/stream ownership tests.

Do not treat these minimums as a substitute for dependency monitoring, lockfile review, SBOMs, release rebuilds and vulnerability scanning.

References:
- https://hex.pm/packages/brotli
- https://hex.pm/packages/brotli/advisories
- https://hex.pm/packages/ezstd
- https://hex.pm/packages/ezstd/advisories
- https://www.erlang.org/doc/apps/erts/erl_nif.html
- https://github.com/erlang/otp/blob/master/erts/preloaded/src/zlib.erl
- https://owasp.org/www-project-web-security-testing-guide/

### 7.11 Compression benchmark gate

Build a repeatable benchmark harness before enabling compression by default.

Payload corpus:
- Typical signaling Protobuf messages.
- Small JSON/control events.
- Participant and track metadata.
- SDP offers/answers.
- Large room snapshots.
- Repetitive text.
- Random/incompressible bytes.
- DataChannel application payloads.
- Real captures sanitized of credentials and personal data.

Test sizes: 128 B, 512 B, 1 KiB, 4 KiB, 16 KiB, 64 KiB, 256 KiB and 1 MiB, subject to negotiated maximums.

Measure:
- Compression/decompression p50, p95 and p99 latency.
- Compression ratio and bytes saved.
- CPU time per input MiB.
- BEAM reductions and scheduler utilization.
- Peak memory and binary memory retention.
- Worker queue depth and saturation.
- Throughput under concurrent connections.
- Effect on signaling latency and media scheduler/packet forwarding latency.

Test multiple levels and concurrency. The chosen policy should optimize the relevant latency/CPU/network objective, not only the smallest compressed output.

---

## 8. WebRTC transport and security requirements

### 8.1 ICE, STUN and TURN

Implement and test:
- ICE gathering and trickle ICE.
- Candidate parsing/validation.
- Host, server-reflexive and relay candidates.
- IPv4 and IPv6.
- UDP blocked / TCP fallback / TURN TLS fallback.
- ICE connection failure and restart.
- Candidate reordering and duplicate candidate messages.
- Stale ICE username fragments/passwords.
- NAT rebinding and interface changes.
- Network switching and mobile handover.
- TURN credential expiry and rotation.
- Relay-only mode.

Do not assume every client can use UDP or directly reach the server.

### 8.2 DTLS and SRTP

- Require DTLS-SRTP for WebRTC media.
- Validate SDP fingerprints and the negotiated DTLS role.
- Reject invalid state transitions and failed handshakes.
- Do not expose plain RTP for WebRTC clients.
- Keep RTP and RTCP multiplexing behavior consistent with negotiated SDP.
- Track DTLS/SRTP transport state independently from the WebSocket signaling state.
- Test disconnects and key/state cleanup.
- Do not log secrets, ICE credentials or SRTP key material.

### 8.3 PeerConnection negotiation

Cover:
- Offer/answer sequencing.
- Trickle and non-trickle ICE.
- Renegotiation.
- Offer glare and rollback behavior supported by the chosen client/profile.
- Rejected m-lines.
- MID/RID matching.
- Codec preference and fmtp compatibility.
- Dynamic payload type mapping.
- Header extension negotiation.
- RTCP mux.
- BUNDLE.
- Publisher/subscriber direction changes.
- Track replacement/removal.
- ICE restart.
- Temporary disconnect and reconnect.
- Browser-specific and mobile-specific SDP variations.

### 8.4 Authentication and authorization

- Use short-lived signed access tokens or one-time connection tickets.
- Validate issuer, audience, signature, expiry, not-before and allowed clock skew.
- Support key rotation and key IDs.
- Scope grants to a tenant, room, participant identity and permissions.
- Separate room join, publish, subscribe, publish-data and admin permissions.
- Do not trust participant identity or metadata supplied by an unauthenticated client.
- Enforce room participant limits and track limits server-side.
- Authenticate signaling before allocating expensive media resources where practical.
- Avoid long-lived tokens in WebSocket URLs. If browser constraints require a URL ticket, use a one-time short-lived ticket and redact it from logs/traces.
- Check Origin explicitly for browser sessions; Origin is not authentication.
- Rate-limit joins, token attempts, SDP renegotiation and message traffic.

---

## 9. SFU media plane

### 9.1 Track publication

Each published track must store:
- Publisher participant ID.
- Stable server track SID.
- PeerConnection ID.
- MID and media kind.
- Codec and fmtp parameters.
- RTP clock rate.
- Payload type mapping.
- SSRC and RID/simulcast encodings.
- Header extension map.
- Track source and mute/ended state.
- Publication permissions and visibility.

Track publication should be transactional from the control plane perspective: a track is not advertised as usable until its transport and negotiated media mapping are valid.

### 9.2 Subscription and routing

- A subscriber can subscribe/unsubscribe independently.
- Subscription authorization is evaluated for every track.
- Track unpublish, participant disconnect or permission revocation tears down associated DownTracks.
- Late subscribers must receive the correct track state and, for video, a usable keyframe.
- Duplicate subscription requests must be idempotent.
- A participant may publish multiple audio/video/data tracks.
- The router must support no-subscriber publishers without unbounded buffering.
- One slow subscriber must not block the publisher or other subscribers.
- The room control process must not be the packet-forwarding bottleneck.

### 9.3 RTP forwarding

The forwarding layer must handle:
- RTP header parsing and validation.
- Sequence numbers and wraparound.
- Timestamp wraparound and clock rates.
- SSRC translation and collision detection.
- Payload type remapping per negotiated subscriber.
- MID/RID and RTP header extensions.
- Marker bits, CSRC lists, extension profiles and padding.
- Codec-specific packetization boundaries.
- Duplicate and out-of-order packets.
- Per-subscriber fan-out and packet ownership.
- Packet pacing and send queue limits.
- Subscriber-specific packet drops on overload.
- Metrics per track/subscriber.

Use the ExWebRTC RTP APIs rather than implementing cryptographic media transport. Verify which RTP header fields ExWebRTC rewrites when sending a packet and how it maps negotiated codecs/extensions in the selected release.

### 9.4 RTCP and retransmission

Support and test:
- Sender Reports and Receiver Reports.
- NACK.
- PLI and FIR/keyframe requests.
- Transport-wide congestion control where negotiated.
- RTT and loss measurement.
- Per-subscriber feedback aggregation.
- Retransmission cache size/time bounds.
- RTX SSRC/payload type mapping where negotiated.
- Feedback suppression or aggregation to avoid feedback storms.
- Circuit-breaker behavior under sustained congestion.

The server must avoid retransmitting packets after their usefulness window and must prevent NACK/PLI floods from amplifying load.

### 9.5 Audio

Initial codec targets:
- Opus for WebRTC.
- PCMU and PCMA for SIP/telephony.

Requirements:
- Correct negotiated sample rate and RTP clock-rate handling.
- Opus RTP clock rate of 48 kHz.
- DTX, FEC and packetization considerations.
- Audio-level header extension when negotiated.
- Active-speaker events.
- Muting and track-ended events.
- Jitter/loss metrics.
- Decode-to-PCM adapter for STT/VAD only when required.
- Avoid transcoding in the SFU relay path.

For the AI path, define a generic media frame with encoding, sample rate, channels, sample count, timestamp, track ID and source. Do not force every WebRTC track through the existing 8 kHz μ-law interface.

### 9.6 Video

After audio forwarding is stable:
- VP8 and H.264 first; add VP9/AV1 only after compatibility and performance proof.
- Simulcast encoding identification and RID mapping.
- SVC support as an explicit capability.
- Per-subscriber layer selection.
- Keyframe requests and keyframe cache policy.
- Resolution and bitrate adaptation.
- Video track pause/resume.
- Layer switching during loss and renegotiation.
- Codec-specific packetization and aggregation.
- RTX and retransmission prioritization.
- Slow consumer policy.

### 9.7 DataChannels

- SCTP association lifecycle.
- Negotiated and in-band channels.
- Ordered/unordered delivery.
- Reliable/partially reliable delivery.
- Stream IDs and resets.
- Maximum message size.
- Message fragmentation/interleaving constraints.
- Backpressure and buffer limits.
- Channel close and reconnect behavior.
- Compression envelope only for appropriate application payloads.

ExWebRTC's optional SCTP dependency and Rust toolchain must be validated before promising DataChannel support.

### 9.8 Recording and egress

Treat recording as a separately supervised subscriber/consumer. It must not block the SFU packet path.

Plan for:
- Track-level and room-level recording.
- Audio-only and audio/video outputs.
- Start/stop idempotency.
- Storage failures and retry policy.
- File encryption and access control.
- Retention and deletion policy.
- Recording metadata and audit logs.
- Egress CPU/memory limits.
- Recording behavior during reconnect and participant replacement.

---

## 10. SIP gateway and PSTN

### 10.1 Separate SIP signaling from RTP media

SIP dialog/control processes should own SIP transactions and call state. RTP media endpoints should be associated with the corresponding room participant/track, but should not be confused with a WebRTC PeerConnection.

### 10.2 SIP behaviors to cover

- UDP, TCP and TLS transports where required.
- INVITE, ACK, CANCEL, BYE, OPTIONS, REGISTER, INFO, UPDATE, REFER and PRACK according to selected feature scope.
- Transaction retransmission timers and duplicate suppression.
- Dialog state and route sets.
- Call-ID, tags, Via branch, CSeq and Contact processing.
- Provisional responses and early media.
- Forking and multiple 2xx handling if supported.
- Authentication and authorization.
- Session timers.
- Re-INVITE, hold/resume and codec changes.
- SDP offer/answer, direction attributes and rejected m-lines.
- DTMF via RFC 4733 and supported INFO modes.
- RTP sequence/timestamp handling, RTCP and jitter.
- NAT and symmetric RTP.
- IPv4/IPv6.
- Call transfer and failure recovery.
- BYE/CANCEL race handling.
- SIPp or equivalent integration tests.

### 10.3 Media codec interoperability

- Negotiate codecs from actual SDP offers/answers.
- PCMU/PCMA for baseline telephony.
- Opus only when both ends and gateway configuration support it.
- Do not infer payload type solely from static values if SDP negotiated a dynamic payload type.
- Maintain separate clock-rate and packetization handling for each codec.
- Transcode only when needed; account for CPU and added latency.
- Handle DTMF events independently from audio where negotiated.

### 10.4 Existing SIP code

The current SIP message parser and RTP helper are not a complete RFC 3261 stack. The current SDP parser is intentionally simple and must be replaced with robust parsing/negotiation. The existing SIPCarrier's SIP response/request and dialog behavior requires a formal review and integration tests before production use.

Use the NkSIP/ersip/Parrot evaluation in Section 4.4 and record the selected dependency or custom scope in an ADR.

---

## 11. Browser, mobile and client SDK strategy

### 11.1 Browser

Build a small official browser SDK around the native protocol:
- Capability probing and ClientHello.
- Authenticated connection.
- Room join/leave.
- PeerConnection setup and SDP/ICE negotiation.
- Publish/subscribe tracks.
- Mute/unmute.
- Reconnect and ICE restart.
- DataChannels.
- Stats and structured events.
- Compression envelope implementation and interoperability vectors.

Use actual CompressionStream and DecompressionStream runtime feature detection, and advertise only working directions/algorithms.

### 11.2 iOS and Android

Implement native SDKs or official-client wrappers with:
- Platform audio permissions.
- Audio session/focus configuration.
- Background audio behavior where allowed by the OS.
- Bluetooth and headset route changes.
- Phone call and OS audio interruptions.
- Network handover.
- Camera lifecycle and capture constraints.
- Reconnection and ICE restart.
- Battery/thermal-aware behavior.
- Capability probing for compression and codecs.

React Native and Flutter wrappers should use the native media implementation; do not assume a JavaScript-only WebRTC stack provides complete mobile lifecycle behavior.

### 11.3 SDK/server compatibility

Maintain:
- A protocol version matrix.
- A browser/platform matrix.
- Golden signaling vectors.
- Compression test vectors for every algorithm/direction.
- SDP fixtures from supported browser and mobile versions.
- Automated end-to-end connection tests.
- A backwards-compatibility policy.

---

## 12. AI agents as room participants

The AI system should become a participant integration rather than a second independent media server.

A voice agent should:
1. Join a room using a service identity and scoped permissions.
2. Subscribe to selected incoming audio tracks.
3. Decode or receive PCM frames through a media-processing adapter for VAD/STT.
4. Keep conversational state in an AgentSession.
5. Generate TTS audio.
6. Publish generated audio as an outbound room track.
7. Stop/flush current output on barge-in.
8. Leave the room and release all resources on completion/failure.

Separate the encoded SFU path from the decoded AI path:
- SFU subscribers should receive encoded RTP packets when no transformation is required.
- STT/VAD may consume decoded PCM.
- TTS output must be encoded and packetized for the negotiated outgoing track.
- Do not force Opus and 48 kHz WebRTC into the current 8 kHz telephony frame contract.
- Keep Twilio/Telnyx/Vonage adapters operational during migration.

---

## 13. Distributed architecture and deployment

### 13.1 Initial deployment

Start with a single media node and one room-owner process per room. This simplifies ownership, reconnect behavior and packet routing.

Add:
- Configurable public ICE address and port range.
- Coturn service and credentials.
- HTTPS/WSS termination.
- Metrics and health checks.
- PostgreSQL for durable tenant/configuration data where needed.
- Secrets from environment/secret manager, not committed defaults.

### 13.2 Multi-node evolution

Later introduce:
- Cluster membership and node health.
- Room allocator.
- Room ownership lease.
- Sticky/redirected client connection to room owner.
- Signaling event relay between nodes.
- Node drain and room migration strategy.
- Redis for control-plane coordination if selected.
- Explicit node-loss recovery.
- Room placement and capacity/load policy.

Do not route each RTP packet through Redis. Redis is for coordination/metadata/event delivery as required, not the media fast path.

### 13.3 Room migration

A room should have one authoritative media owner in V1 distributed mode. Moving an active room requires an explicit migration protocol:
- Stop or redirect new joins.
- Notify connected participants.
- Transfer room/track/subscription state where technically possible.
- Re-establish PeerConnections or use a documented reconnect process.
- Preserve participant identity and idempotency.
- Verify track re-publication and AI agent recovery.
- Roll back or fail cleanly if the new owner cannot accept the room.

Do not imply transparent media migration until it has been implemented and tested.

---

## 14. Security and abuse prevention

Security requirements apply to signaling, media and application messages.

### 14.1 Connection security

- WSS/HTTPS in production.
- Explicit Origin validation.
- Short-lived signed tokens / one-time connection tickets.
- Tenant and room scoped grants.
- Rate limiting and concurrent connection limits.
- Replay protection and expiry.
- Key rotation.
- No credentials in logs.
- Structured security audit events.

### 14.2 Media security

- DTLS-SRTP for WebRTC.
- SRTCP for RTCP.
- Validate fingerprints and negotiated transports.
- Do not expose plaintext keys or ICE passwords.
- Limit track count, bitrate, resolution and packet rate.
- Prevent unauthorized publish/subscribe.
- Validate RTP/RTCP structures and payload bounds.
- Avoid expensive per-packet allocations where possible.

### 14.3 Resource abuse

- Maximum rooms and participants per tenant.
- Maximum PeerConnections per participant.
- Maximum published/subscribed tracks.
- Maximum SDP size and renegotiation frequency.
- Maximum DataChannel message size.
- Maximum WebSocket message size.
- Bounded queues and mailbox thresholds.
- Compression CPU/ratio/output bounds.
- Rate limits on NACK/PLI and other feedback.
- Room and node admission control.
- Graceful overload and rejection paths.

### 14.4 Supply chain

- Pin dependencies via lockfile.
- Review native NIF/Rust/C build requirements.
- Generate SBOMs.
- Scan Hex and OS dependencies.
- Monitor Hex advisories and upstream security releases.
- Keep minimum patched versions for compression packages.
- Build and test supported Linux images.
- Rebuild release artifacts after native library security updates.

---

## 15. Observability and SLO candidates

Do not settle numerical SLOs until the first benchmark baseline exists. Capture at least:

### Connection and signaling
- Handshake duration.
- Authentication failure counts.
- Room join/leave latency.
- SDP negotiation duration.
- ICE gathering and connection time.
- DTLS handshake duration.
- Disconnect reasons.
- Reconnect and ICE restart success.

### Media
- RTP packets/bytes in and out.
- Per-track and per-subscriber packet loss.
- Jitter and RTT.
- NACK/PLI/FIR rates.
- Retransmission hit/miss.
- Forwarding queue depth and drops.
- Audio/video bitrate.
- Selected simulcast layer.
- DataChannel buffered amount and errors.

### Compression
- Algorithm selected in each direction.
- Payload class and size bucket.
- Compression ratio.
- Compression/decompression p50/p95/p99.
- CPU and memory.
- Rejections and malformed frames.
- Decompression output-limit failures.
- Worker queue saturation.

### AI and telephony
- STT first partial/final latency.
- LLM time to first token.
- TTS time to first audio.
- Barge-in stop latency.
- Media conversion latency.
- SIP setup duration and call failure codes.

Never put access tokens, private SIP credentials, SDP secrets or raw user audio into general-purpose logs. Recording/transcription retention must be governed by explicit product settings.

---

## 16. Testing strategy and edge-case matrix

The plan is not complete if it lists only features. Every stateful subsystem must have tests for normal flow, duplicate flow, out-of-order flow, malformed input, timeout, overload and process/node failure.

### 16.1 Required test layers

1. Unit tests for parsers, codecs, envelope, state machines and mapping rules.
2. Property tests for RTP sequences/timestamps, packet parsing, negotiation intersections, length validation and SIP message parsing.
3. Fuzz tests for Protobuf, SDP, RTP/RTCP, SIP and compressed envelopes.
4. Golden test vectors for compression algorithms and protocol versions.
5. Integration tests with real browser clients.
6. Browser compatibility tests across Chromium, Firefox and WebKit where supported.
7. Native iOS/Android tests.
8. SIPp-based SIP integration tests and PBX/carrier interoperability.
9. Network impairment tests using loss, delay, jitter, reordering, bandwidth limits, packet duplication and disconnect/reconnect.
10. Soak tests and capacity/load tests.
11. Failure injection for process crashes, NIF errors, worker saturation, Redis/node loss and storage failure.
12. Security tests for auth, permissions, resource exhaustion and compression-bomb defenses.

### 16.2 Edge-case acceptance matrix

| Area | Required cases |
|---|---|
| Signaling | Duplicate request IDs; unknown message type; invalid protocol version; invalid Protobuf; partial frame; oversized message; handshake timeout; event arrives before state is ready |
| Compression | No common algorithm; client only encodes or only decodes an algorithm; wrong algorithm ID; compressed before negotiation; malformed/truncated stream; declared length mismatch; output exceeds cap; expansion ratio exceeded; compression expands data; NIF failure; client reconnects with different support |
| Authentication | Expired token; not-yet-valid token; invalid signature; wrong tenant; revoked participant; replayed one-time ticket; rotated key; clock skew |
| Room lifecycle | Concurrent create/join; duplicate participant identity; room full; room deleted during join; owner process crash; participant reconnect; stale registration; participant leaves during publish |
| SDP | Glare; repeated offer; rejected media section; codec mismatch; unsupported fmtp; missing MID; missing ICE credentials; malformed candidate; stale candidate after restart |
| ICE | IPv4/IPv6; UDP blocked; relay-only; TURN auth expired; candidate reordering; duplicate candidate; NAT change; network handoff; ICE restart race |
| DTLS/SRTP | Wrong fingerprint; bad certificate; handshake timeout; invalid state; transport restart; SRTP packet authentication failure |
| RTP | Invalid version; malformed extension; bad padding; unexpected payload type; unknown SSRC; collision; sequence wrap; timestamp wrap; duplicate; reorder; late packet; packet larger than MTU/buffer |
| RTCP | Malformed compound packet; invalid length; NACK storm; repeated PLI; invalid sender report; unknown media SSRC; feedback for removed track |
| SFU | Publisher leaves; subscriber leaves; late subscriber; simultaneous subscriptions; track replacement; no subscribers; slow consumer; one receiver saturated; unauthorized subscription |
| Video | No keyframe; keyframe request storm; RID changes; layer removed; SVC mismatch; codec renegotiation; abrupt resolution/bitrate change |
| DataChannel | SCTP not installed; SCTP setup error; stream reset; unordered channel; partial reliability; message too large; channel closed during send; application envelope invalid |
| SIP | Retransmitted INVITE; CANCEL/200 race; multiple 2xx; ACK/BYE race; early media; re-INVITE glare; malformed SDP; dynamic payload type; NAT asymmetric RTP; DTMF duplication/loss; authentication challenge |
| Mobile | Permission revoked; app backgrounded; OS interruption; Bluetooth device removed; Wi-Fi/cellular handoff; network loss; process killed; device thermal/battery constraint |
| Distributed | Redis unavailable; lease expires; two nodes claim same room; room owner dies; client reconnects to wrong node; node draining; stale presence; partial partition |
| Backpressure | Full mailbox; queue limit reached; slow NIF; decompression pool saturated; slow subscriber; disk/storage unavailable; control-plane overload |
| Security | Origin spoofing; token replay; cross-tenant join; unauthorized publish; room enumeration; message flood; decompression bomb; compression side channel; malformed native input |

For every test, define expected behavior: reject, retry, reconnect, shed load, drop packet, close one participant, close a room, or mark a node unhealthy. Avoid vague expectations like "handle gracefully".

---

## 17. Implementation roadmap and exit criteria

### Phase 0 — Foundation research and technical spikes

Tasks:
- Verify ExWebRTC 0.18.0 against the current Elixir/OTP build matrix.
- Establish a browser PeerConnection and exchange SDP/ICE.
- Receive and send RTP using the actual 0.18 API.
- Test Opus negotiation and packet forwarding feasibility.
- Test DataChannels with ex_sctp and its Rust build requirements.
- Compare native NIF/build requirements in release containers.
- Benchmark gzip, Brotli and Zstd on representative messages.
- Verify safe bounded decompression APIs and patched package versions.
- Test browser capability probing on supported browser versions.
- Compare SIP stack candidates and compatibility.
- Write ADRs for protocol mode, PeerConnection topology and compression envelope.

Exit criteria:
- Browser-to-Elixir PeerConnection works.
- The server can receive and send a media packet using supported APIs.
- DataChannel feasibility and build path are documented.
- Compression benchmark harness runs and all three algorithm paths have round-trip tests.
- SIP recommendation is evidence-based.
- Known blockers and unsupported features are written down.

### Phase 1 — Native signaling and connection bootstrap

Tasks:
- Implement WebSocket signaling.
- Implement ClientHello / ServerHello.
- Implement protocol version and capability negotiation.
- Implement directional compression selections and the application envelope.
- Implement authentication, one-time connection tickets and room join/leave API.
- Implement SDP/ICE request handling.
- Implement timeout, duplicate, malformed and downgrade handling.
- Add structured protocol errors.

Exit criteria:
- Browser clients can negotiate protocol/capabilities and establish WebRTC connections.
- Compression mismatch and malformed input cannot crash the server.
- Uncompressed fallback works.
- Existing telephony endpoints remain unaffected.

### Phase 2 — Rooms, participants and tracks

Tasks:
- Room registry and lifecycle.
- Participant supervision and identity.
- PeerConnection ownership.
- Publish/unpublish lifecycle.
- Track registry and subscriptions.
- Permission checks and cleanup.
- Room and participant events.

Exit criteria:
- Multiple clients join one room.
- Publish/unpublish and join/leave are idempotent.
- Crashing one participant does not terminate the room.

### Phase 3 — Audio-only SFU

Tasks:
- Implement UpTrack/DownTrack mapping.
- Receive RTP and fan out to authorized subscribers.
- Track codec/PT/SSRC/extension mappings.
- Implement send queues and pacing.
- Handle packet loss/reorder and initial RTCP feedback.
- Add per-track/per-subscriber telemetry.

Exit criteria:
- Two or more browsers exchange live audio through the Elixir SFU.
- A slow subscriber cannot block other participants.
- Publisher departure removes its tracks/subscriptions.
- Network impairment tests have defined expected outcomes.

### Phase 4 — Reliability and congestion management

Tasks:
- NACK/RTX.
- PLI/FIR.
- TWCC and congestion estimation.
- Queue/backpressure controls.
- Subscriber bitrate policies.
- ICE restart/reconnect.
- Room failure cleanup.
- Soak and capacity tests.

Exit criteria:
- Stable call under defined packet loss, jitter and bandwidth constraints.
- No unbounded queue/memory growth in stress tests.
- Measured latency and capacity baseline.

### Phase 5 — Video SFU

Tasks:
- VP8/H.264.
- Simulcast.
- SVC where supported.
- Keyframe and layer management.
- Adaptive stream forwarding.
- Video queue/backpressure policy.

Exit criteria:
- Multiple browser clients can publish/subscribe video with adaptive layer selection and stable memory/CPU.

### Phase 6 — DataChannels and application data

Tasks:
- Complete SCTP lifecycle.
- Implement reliable/unreliable profiles.
- Implement application message limits and flow control.
- Apply negotiated compression to eligible application envelopes.
- Add file/data streams and cancellation.

Exit criteria:
- DataChannels pass browser interoperability tests.
- Compression selection/fallback/security tests pass for every supported algorithm and direction.

### Phase 7 — AI agent and SIP integration

Tasks:
- AI agent as a participant.
- Audio decode/copy pipeline for STT/VAD.
- TTS publication into room tracks.
- Barge-in and playout control.
- SIP stack selection and implementation.
- SIP/RTP room participant adapter.
- G.711/Opus codec interoperability.
- SIPp and carrier integration tests.

Exit criteria:
- Browser, SIP and AI agent participants can interact in one room.
- Existing carrier integrations continue to pass regression tests.

### Phase 8 — Distributed and production readiness

Tasks:
- Node health and room placement.
- Redis-based control-plane coordination if selected.
- Graceful draining.
- Room ownership and recovery.
- TURN deployment hardening.
- Recording/egress.
- Security review and SBOM.
- Production capacity and cost benchmarks.

Exit criteria:
- Documented deployment, recovery, scaling, security and operational runbooks.
- Tested node-loss and reconnect behavior.
- Production SLOs derived from measured results.

---

## 18. Required ADRs before implementation

These decisions need explicit answers and should be recorded under docs/adr/ when approved:

1. Native E-Voice protocol only, or unmodified LiveKit SDK compatibility as a release-one requirement?
2. Single Unified Plan PeerConnection or separate publisher/subscriber PeerConnections in the native topology?
3. Signaling encoding: Protobuf-only, JSON bootstrap plus Protobuf, or another versioned format?
4. Compression envelope exact binary layout and whether profiles are per direction only or per traffic class.
5. Compression level/threshold policy, based on benchmark results.
6. ExWebRTC DataChannel dependency and native build strategy.
7. SIP stack choice: NkSIP, ersip-based integration, Parrot evaluation, or custom bounded SIP scope.
8. Codec roadmap and H.264 licensing/deployment constraints.
9. Room persistence and Redis coordination model.
10. Recording and media retention/security model.

Do not implement a decision that materially affects protocol compatibility without an ADR.

---

## 19. First implementation backlog

The first code PR should be limited to a proof of concept and must not attempt the entire SFU:

1. Add a separate experiment/application module or isolated test branch for ExWebRTC.
2. Add a minimal authenticated browser signaling connection.
3. Establish one PeerConnection and complete SDP/ICE negotiation.
4. Receive a browser Opus RTP track.
5. Inspect RTP/RTCP events and stats.
6. Create a second PeerConnection and forward the received packet to a subscriber.
7. Verify actual browser playout and teardown.
8. Add a compression microbenchmark separate from the media test.
9. Verify uncompressed ClientHello/ServerHello and one round-trip per compression algorithm.
10. Add network impairment and participant crash tests.

The proof of concept should be merged only after its dependency/build model and the media packet path are understood. It should not yet claim production SFU behavior.

---

## 20. Reference material

### E-Voice-Kit repository baseline
- https://github.com/FLCN-16/e-voice-kit/tree/develop
- https://github.com/FLCN-16/e-voice-kit/blob/develop/mix.exs
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/application.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/endpoint.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/pipeline/session.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/transports/sip_carrier.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/transports/sip/rtp.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/transports/sip/message.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/transports/websocket_carrier.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/providers/carrier.ex

### WebRTC and media standards
- RFC 3550 — RTP: https://www.rfc-editor.org/rfc/rfc3550
- RFC 8834 — Media Transport and Use of RTP in WebRTC: https://www.rfc-editor.org/rfc/rfc8834
- RFC 8835 — Transports for WebRTC: https://www.rfc-editor.org/rfc/rfc8835
- RFC 8827 — WebRTC Security Architecture: https://www.rfc-editor.org/rfc/rfc8827
- RFC 8445 — ICE: https://www.rfc-editor.org/rfc/rfc8445
- RFC 8489 — STUN: https://www.rfc-editor.org/rfc/rfc8489
- RFC 8656 — TURN: https://www.rfc-editor.org/rfc/rfc8656
- RFC 8261 — SCTP over DTLS: https://www.rfc-editor.org/rfc/rfc8261
- RFC 8841 — SDP Offer/Answer for SCTP Data Channels: https://www.rfc-editor.org/rfc/rfc8841

### ExWebRTC / Elixir media
- ExWebRTC 0.18.0: https://hex.pm/packages/ex_webrtc/0.18.0
- ExWebRTC dependencies: https://hex.pm/packages/ex_webrtc/0.18.0/dependencies
- ExWebRTC source: https://github.com/elixir-webrtc/ex_webrtc
- ExSCTP: https://hex.pm/packages/ex_sctp
- Membrane: https://github.com/membraneframework
- Membrane WebRTC Plugin: https://github.com/membraneframework/membrane_webrtc_plugin
- Archived Membrane RTC Engine: https://github.com/fishjam-cloud/membrane_rtc_engine

### LiveKit protocol and architecture references
- LiveKit SFU architecture: https://docs.livekit.io/reference/internals/livekit-sfu/
- LiveKit client protocol: https://docs.livekit.io/reference/internals/client-protocol/
- LiveKit RTC Protobuf: https://github.com/livekit/protocol/blob/main/protobufs/livekit_rtc.proto
- LiveKit models Protobuf: https://github.com/livekit/protocol/blob/main/protobufs/livekit_models.proto

### Compression and runtime references
- RFC 7692 — WebSocket Compression Extensions: https://www.rfc-editor.org/rfc/rfc7692
- RFC 7932 — Brotli: https://www.rfc-editor.org/rfc/rfc7932
- RFC 1952 — GZIP: https://www.rfc-editor.org/rfc/rfc1952
- RFC 8478 — Zstandard: https://www.rfc-editor.org/rfc/rfc8478
- MDN CompressionStream: https://developer.mozilla.org/en-US/docs/Web/API/CompressionStream/CompressionStream
- Erlang zlib: https://www.erlang.org/doc/apps/erts/zlib.html
- Erlang NIF/dirty scheduler guidance: https://www.erlang.org/doc/apps/erts/erl_nif.html
- Brotli Hex package and advisories: https://hex.pm/packages/brotli
- Zstandard Hex package and advisories: https://hex.pm/packages/ezstd

### SIP references
- RFC 3261 — SIP: https://www.rfc-editor.org/rfc/rfc3261
- RFC 3264 — SDP Offer/Answer: https://www.rfc-editor.org/rfc/rfc3264
- RFC 4733 — RTP DTMF events: https://www.rfc-editor.org/rfc/rfc4733
- NkSIP: https://github.com/erlnets/nksip
- ersip: https://github.com/poroh/ersip
- Parrot platform: https://github.com/byoungdale/parrot

---

## 21. Approval checklist

Before implementation begins, approve or amend these project-level choices:

- [ ] The product is a native Elixir SFU/real-time media server, not a LiveKit integration.
- [ ] Existing telephony and AI-provider functionality must remain available during migration.
- [ ] The first milestone is browser-to-browser audio through the Elixir SFU.
- [ ] ExWebRTC is the preferred foundation, subject to Phase 0 technical validation.
- [ ] Brotli, gzip and Zstandard are negotiated by directional client/server capability intersection on every new signaling connection.
- [ ] Compression is application-envelope compression for signaling/application data, not general-purpose RTP/SRTP compression.
- [ ] none is mandatory fallback; limits, no-context-takeover and decompression safety are mandatory.
- [ ] Native protocol versus unmodified LiveKit SDK compatibility is explicitly decided before the production protocol is frozen.
- [ ] SIP stack choice is gated on research and integration testing.
- [ ] No production code changes are included in this documentation-only commit.

**This plan is a researched proposal, not a claim that all listed capabilities already exist. The architecture, APIs, dependencies and versions must pass the specified proof-of-concept and compatibility gates before implementation.**
