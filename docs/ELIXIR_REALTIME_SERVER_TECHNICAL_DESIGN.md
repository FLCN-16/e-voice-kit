# E-Voice-Kit Native Elixir Real-Time Server
## Deep Technical Design and Engineering Reference

> Document type: Detailed technical design / implementation reference  
> Status: Proposed design; not an implementation claim  
> Prepared: 2026-11-20  
> Repository baseline: develop branch  
> Companion: ELIXIR_REALTIME_SERVER_PLAN.md  
> Scope: Documentation only

## Document conventions

This document separates four kinds of statements:

- **Repository fact** — behavior or structure directly observed in the inspected E-Voice-Kit source.
- **Upstream fact** — documented behavior of a protocol, standard, dependency or reference implementation. A link is supplied where practical.
- **Design proposal** — a recommended design for E-Voice-Kit. It is not implemented yet.
- **Validation requirement** — a behavior that must be proven with a test, benchmark or interoperability run before it is treated as supported.

A capability listed here is not automatically supported by ExWebRTC, Membrane, Bandit or the existing application. The exact dependency version, build, API, protocol negotiation and test evidence must be recorded before the capability is declared complete.

“LiveKit-like” refers to architecture and product capability. It does not mean that the native protocol described here is wire-compatible with LiveKit. Compatibility requires a separate adapter and conformance testing.

## Table of contents

1. Product goal and system boundaries
2. Existing repository: observed state and migration boundaries
3. Terminology and object model
4. Protocol stack and network topology
5. End-to-end call and media flows
6. Elixir/OTP architecture and process ownership
7. Signaling protocol
8. Connection bootstrap and authentication
9. Compression capability negotiation
10. Compression binary envelope and codec contracts
11. Compression implementation, safety and benchmarks
12. WebRTC negotiation and peer-connection lifecycle
13. ICE, STUN, TURN and NAT traversal
14. DTLS, SRTP and transport security
15. RTP packet model and packet-processing requirements
16. SFU architecture and packet forwarding
17. RTCP, retransmission and congestion control
18. Audio media
19. Video media, simulcast and SVC
20. WebRTC DataChannels
21. Media processing, recording and egress
22. AI-agent participant architecture
23. SIP signaling and PSTN gateway
24. Browser, mobile and native SDK requirements
25. Room APIs and control-plane operations
26. Data model and persistence boundaries
27. Distributed deployment and room placement
28. Backpressure, overload and graceful draining
29. Security and threat model
30. Observability and operational diagnostics
31. Testing, interoperability and fault injection
32. Deployment reference
33. Proposed module map
34. Implementation sequence and engineering gates
35. Architecture decisions still requiring approval
36. Glossary
37. Standards, upstream projects and source references

---

# 1. Product goal and system boundaries

## 1.1 Goal

Build a real-time communications server in Elixir/OTP that provides the main server-side capabilities expected from an SFU product:

- Signaling over WebSocket.
- Room, participant and track lifecycle.
- WebRTC PeerConnection management.
- ICE negotiation and NAT traversal.
- DTLS-SRTP secure media transport.
- RTP and RTCP parsing, routing, feedback and retransmission.
- Audio/video selective forwarding.
- DataChannel termination and application-level relay.
- Permissions and subscription policy.
- Client capability negotiation.
- Brotli, gzip and Zstandard compression for eligible application messages.
- Browser and mobile client support.
- SIP/PSTN gateway integration.
- AI agents that join rooms, consume audio and publish generated audio.
- Recording and other media consumers.
- Metrics, diagnostics, multi-tenant controls and eventual multi-node deployment.

## 1.2 The fundamental separation

The server has two principal planes.

### Control plane

The control plane manages authentication, authorization, signaling sessions, room and participant records, PeerConnection lifecycle, SDP/ICE negotiation, published tracks and subscriptions, mute/metadata/permissions/room events, compression capability negotiation for application messages, reconnect, room ownership and node placement.

### Media plane

The media plane manages UDP/WebRTC packet ingress and egress, DTLS and SRTP protection, RTP/RTCP, packet forwarding, header mapping and per-subscriber stream identity, retransmissions and feedback, congestion response and layer selection, and optional decode/encode pipelines for media consumers.

The signaling WebSocket is not the audio/video media transport. WebRTC media normally flows over ICE-selected network paths as SRTP/SRTCP; DataChannels use SCTP over DTLS over ICE. RFC 8835 and RFC 8831 define these transport requirements.

## 1.3 SFU, not MCU, as the primary forwarding model

The primary media server should be an SFU:

1. A publisher sends an encoded RTP stream.
2. The server terminates that participant's secure transport.
3. The server identifies the track and packet stream.
4. The server forwards the encoded packet content to subscribers that are authorized and subscribed.
5. Each subscriber receives packets over its own secure transport.

A normal SFU path does not decode every audio/video frame and re-encode it for all receivers. Decoding is reserved for features that actually require media samples or frames, such as STT, VAD, recording, transcoding or computer vision.

LiveKit describes its SFU as an adaptive forwarding system that estimates downstream bandwidth and chooses a suitable quality layer for each subscriber. Its distributed deployment routes room participants to a room-owning node, using Redis for coordination in a multi-node deployment. These are reference architecture concepts, not a claim that E-Voice-Kit already implements them.

## 1.4 First technical milestone

The first end-to-end proof is deliberately restricted:

- Start the Elixir application.
- Open a browser client with a short-lived join ticket.
- Complete signaling and WebRTC negotiation.
- Join a room.
- Join a second browser to the same room.
- Publish microphone audio from the first browser.
- Receive RTP in the Elixir server.
- Route it to the second participant.
- Send it through the second participant's WebRTC connection.
- Play it in the second browser.
- Disconnect either participant and clean up without stopping the room or the other participant.

No external LiveKit process, SFU or media server may be involved in this proof.

---

# 2. Existing repository: observed state and migration boundaries

The following are repository facts observed from the inspected develop snapshot on 2026-11-20.

## 2.1 Runtime baseline

The current Mix project:
- Declares Elixir approximately 1.15.
- Names the OTP application E-Voice-Kit.
- Uses Bandit and WebSockAdapter for inbound HTTP/WebSocket.
- Uses Finch for outbound HTTP.
- Uses Jason and Msgpax for application/provider data.
- Uses WebSockex for outbound provider WebSockets.
- Uses Telemetry.
- Does not currently declare ExWebRTC, ExSCTP, Membrane, a compression NIF package or a SIP transaction framework in the inspected dependency list.

The exact production OTP version and container toolchain should be checked in the release build before selecting native dependencies.

## 2.2 Existing supervision tree

Observed children in EVoiceKit.Application:
- Registry named EVoiceKit.SessionRegistry.
- Finch named EVoiceKit.Finch.
- Task.Supervisor named EVoiceKit.TaskSupervisor.
- EVoiceKit.Pipeline.SessionSupervisor.
- Bandit serving EVoiceKit.Endpoint.

The existing application uses one-for-one supervision at the root.

## 2.3 Existing HTTP and WebSocket routes

The inspected endpoint includes:
- GET /health.
- GET /media/twilio.
- GET /media/telnyx.
- GET /media/vonage.
- POST /twiml.
- Call reconfiguration and carrier webhook routes.

The inspected router does not implement a WebRTC room signaling route or a browser media route. The README mentions a browser URL ending in /media/web, but this route was not found in the inspected endpoint. The discrepancy should be corrected in documentation or implemented before that URL is presented as supported.

The inspected endpoint applies wildcard CORS. That is not an acceptable final browser security policy by itself. WebSocket Origin checks, authentication and CORS rules must be considered separately.

## 2.4 Existing AI session

The existing Pipeline.Session:
- Is a GenServer for a single live call.
- Requires a transport_pid.
- Monitors the transport process.
- Starts STT and TTS provider clients.
- Starts either a native LLM Agent or a BrainBridge.
- Receives caller audio as μ-law bytes.
- Passes audio to the STT provider.
- Sends synthesized audio chunks back to the transport.
- Handles speech start, speech end, transcription, interruption, hangup and DTMF events.
- Uses a listening/thinking/speaking/ended status model.
- Uses a telephony buffer initialized with 160-byte frames.

This is useful for the existing telephony AI gateway. It is not a room-level SFU abstraction and should not be reused as the owner of all participant media.

## 2.5 Existing audio buffer

Pipeline.Buffer currently:
- Has a default packet size of 160 bytes.
- Documents 20 ms at 8 kHz G.711.
- Accumulates incoming chunks and yields fixed-size packets.
- Flushes pending bytes on an interruption.

This is a telephony-specific assumption. WebRTC Opus packets are not guaranteed to align to 160-byte chunks or 20 ms payloads. A generic audio-frame model must include codec, clock rate, channel count, sample count and timestamp.

## 2.6 Existing carrier contract

Providers.Carrier currently expresses media in 8 kHz G.711 μ-law. WebSocketCarrier uses carrier-specific callbacks to decode and encode media/control frames.

Do not expand this contract to represent all WebRTC tracks. Retain it as a telephony adapter contract and introduce a separate room/media transport API.

## 2.7 Existing SIP prototype

The current SIP RTP helper:
- Encodes a simple 12-byte RTP fixed header.
- Uses payload type 0 for PCMU and 8 for PCMA constants.
- Parses version, payload type, sequence, timestamp, SSRC and CSRC count.
- Skips CSRC values.
- Does not currently parse/serialize the complete header extension or RTP padding model.
- Does not implement complete RTCP handling in the inspected helper.

The current SIP message helper:
- Parses a basic SIP request/response start line.
- Parses a simple header map.
- Builds SIP responses.
- Extracts an IPv4 connection address and audio port using a simple SDP regular expression.

This is a useful prototype for narrow tests, not a complete SIP stack. SIP requires transaction and dialog state, retransmission timers, reliable and unreliable transport behavior, SDP offer/answer semantics and numerous race cases. See RFC 3261.

## 2.8 Migration rule

Add the RTC/SFU domains alongside the current telephony path. Preserve current carrier tests and functionality. Only migrate AI session APIs after the new media-frame interface has regression tests against existing μ-law carriers.

---

# 3. Terminology and object model

These terms should be used consistently throughout code, logs, metrics and protocol messages.

| Term | Definition |
|---|---|
| Tenant | Security and billing boundary that owns rooms, users, credentials and policy |
| Room | Logical multi-party communication session |
| Participant | A connected identity inside a room |
| PeerConnection | A negotiated WebRTC transport endpoint |
| Transport | The ICE/DTLS/SRTP/SCTP path associated with a PeerConnection |
| Track | A logical audio, video or data source published by a participant |
| RTP stream | A packet stream identified primarily by SSRC and negotiated media context |
| UpTrack | The server's representation of an incoming publisher track |
| DownTrack | A subscriber-specific representation of a forwarded track |
| Subscription | Authorization and routing relationship between a subscriber and a published track |
| RID | RTP stream identifier used for simulcast stream restrictions/identification |
| MID | SDP media identification attribute used to correlate a media section/transceiver |
| SSRC | RTP synchronization source identifier |
| PT | RTP payload type |
| RTX | RTP retransmission stream format |
| TWCC | Transport-wide congestion control feedback mechanism |
| PLI | Picture Loss Indication |
| FIR | Full Intra Request |
| AgentSession | Conversational/AI state associated with an agent participant |
| SIP Dialog | SIP session relationship between endpoints |
| SIP Transaction | Stateful request/response exchange with timers and retransmissions |
| Room Owner | Media node that is authoritative for a room in distributed deployments |

## 3.1 Cardinality

Do not assume a one-to-one mapping between these entities.

- One tenant owns many rooms.
- One room contains many participants.
- A participant may have one or more PeerConnections depending on protocol mode and product compatibility requirements.
- A participant may publish multiple tracks.
- A track may have multiple RTP encodings (simulcast) and multiple RTP SSRCs.
- A track may have many subscribers.
- A participant may subscribe to many tracks.
- One participant identity may be associated with a browser, mobile client, SIP leg or AI agent.
- One AgentSession may listen to multiple selected tracks and publish one or more output tracks.
- A SIP Dialog may bridge a room participant to RTP media, but is not itself a WebRTC PeerConnection.

## 3.2 Stable identifiers

Use opaque, collision-resistant identifiers:
- tenant_id
- room_sid
- participant_sid
- peer_connection_id
- track_sid
- subscription_id
- agent_session_id
- sip_dialog_id

Do not use a client-supplied participant name as a primary key. Client identity must be authorized by the server-issued access grant.

---

# 4. Protocol stack and network topology

## 4.1 Browser/mobile signaling path

~~~text
Browser / Mobile SDK
      |
      | HTTPS: request short-lived connection ticket
      v
E-Voice-Kit HTTP API (Bandit)
      |
      | WSS upgrade + one-time ticket
      v
Signaling Session
      |
      | ClientHello / ServerHello
      | room join, SDP, ICE candidates, track control
      v
Room + Participant + PeerConnection owner
      |
      | ICE-selected UDP path (or TURN relay)
      v
DTLS handshake
      |
      +---- SRTP / SRTCP media
      |
      +---- SCTP DataChannels over DTLS
~~~

## 4.2 SIP path

~~~text
SIP endpoint / PBX / carrier
      |
      | SIP signaling over UDP, TCP or TLS
      v
SIP ingress / transaction layer
      |
      | Dialog and SDP offer/answer
      v
SIP call-leg process
      |
      | RTP / SRTP media
      v
Room participant adapter
      |
      v
Room track registry / SFU / AI services
~~~

SIP signaling and RTP media are separate flows. Do not assume a SIP request's source address/port is the correct RTP destination. SDP media connection information, symmetric RTP behavior, NAT and negotiated attributes must be processed.

## 4.3 Media security boundary

For a WebRTC participant:
1. The browser creates RTP media packets.
2. Its WebRTC stack protects them using SRTP.
3. ICE selects the network path.
4. The server's WebRTC transport authenticates and decrypts the incoming media.
5. The application receives an RTP packet event from the WebRTC library.
6. The SFU makes a track/subscription routing decision.
7. The destination PeerConnection serializes the packet for its own sender track and protects the outgoing packet with its own transport keys.

**Important:** the server cannot simply copy the publisher's encrypted SRTP datagram to another participant. The publisher and each subscriber have independent transport security associations and keys. Packet forwarding happens after terminating the ingress WebRTC security context and before creating the destination participant's protected packet.

References: RFC 8827, RFC 5764, RFC 8834.

---

# 5. End-to-end call and media flows

## 5.1 Browser connection bootstrap

1. Client obtains a short-lived, single-use connection ticket over HTTPS.
2. Client opens WSS to the RTC signaling endpoint.
3. Server validates the ticket, tenant, expiry and one-time nonce.
4. Client sends uncompressed ClientHello.
5. Server validates protocol versions, client limits and advertised capabilities.
6. Server computes directional codec intersections.
7. Server sends uncompressed ServerHello.
8. Client validates selections and sends uncompressed ClientReady.
9. Server acknowledges readiness with uncompressed ServerReady.
10. Both sides enter the negotiated signaling state.
11. Client joins a room and provides participant preferences.
12. Server creates/attaches participant and PeerConnection ownership.
13. Offer/answer and ICE candidate exchange occurs.
14. WebRTC ICE/DTLS state becomes connected.
15. Participant and track events are emitted.
16. The server begins routing media.

## 5.2 Audio publication

~~~text
Mic capture
  -> browser audio processing / Opus encoder
  -> RTP packetizer
  -> SRTP protect
  -> ICE network path
  -> E-Voice server SRTP decrypt
  -> ExWebRTC RTP event
  -> map (PeerConnection, track_id, RID, RTP packet)
  -> identify UpTrack
  -> resolve subscription routing state
  -> per-subscriber DownTrack
  -> subscriber PeerConnection sender packet path
  -> SRTP protect using subscriber transport
  -> ICE network path
  -> subscriber browser SRTP decrypt
  -> jitter buffer / Opus decode
  -> audio output device
~~~

The SFU must not decode/re-encode the Opus payload in this normal path.

## 5.3 AI consumption

~~~text
Publisher Opus RTP
    |
    +---- encoded SFU forwarding -> room subscribers
    |
    +---- optional media consumer
              -> Opus decoder
              -> PCM frame adapter
              -> VAD / STT streaming client
              -> transcript events
              -> AgentSession
              -> LLM / tools
              -> TTS
              -> PCM or encoded audio
              -> packetizer / Opus encoder
              -> outbound room audio track
~~~

This creates an independent AI consumer. It must not make the ordinary SFU forwarding path wait for STT or TTS.

## 5.4 Participant disconnect

1. PeerConnection state enters failed/closed or signaling/WebSocket session disappears.
2. Server starts a bounded disconnect grace period if reconnection is supported.
3. If reconnect succeeds and the protocol supports state reconciliation, preserve logical participant identity and synchronize tracks/subscriptions.
4. Otherwise mark participant disconnected and initiate cleanup.
5. Unpublish tracks and remove UpTracks.
6. Remove DownTracks/subscriptions associated with publisher tracks.
7. Close or invalidate PeerConnection resources.
8. Notify remaining participants.
9. Stop or reassign AI subscriptions if the AI session depends on that publisher.
10. Release registries, monitors, timers and per-connection compression state.

A signaling WebSocket disconnect does not necessarily mean that the underlying media path is already unusable. The implementation must define the relationship between signaling loss and media liveness.

## 5.5 Room join idempotency

A join must have an explicit request_id/idempotency key. Duplicate retries should either return the existing participant/session result where safe, or return a structured duplicate/conflict error.

Never create two room participants merely because an HTTP retry or reconnect repeated the same join intent.

---

# 6. Elixir/OTP architecture and process ownership

## 6.1 Architectural principle

Use OTP processes for independently owned state and lifecycle. Do not create a process for every RTP packet. Packet handling should remain within bounded owner processes or carefully designed media workers.

The process model is a design tool, not a reason to put every operation behind a synchronous GenServer call.

## 6.2 Proposed supervision tree

~~~text
EVoiceKit.Application
├── EVoiceKit.ConnectionRegistry
├── EVoiceKit.RoomRegistry
├── EVoiceKit.TenantPolicyCache
├── EVoiceKit.RoomDynamicSupervisor
│   └── EVoiceKit.RoomSupervisor (one per room)
│       ├── EVoiceKit.RoomCoordinator
│       ├── EVoiceKit.ParticipantDynamicSupervisor
│       │   └── EVoiceKit.ParticipantSession (one per participant)
│       │       ├── EVoiceKit.SignalingSession
│       │       └── EVoiceKit.PeerConnectionOwner (one per PeerConnection)
│       ├── EVoiceKit.TrackRegistry
│       ├── EVoiceKit.SubscriptionManager
│       └── EVoiceKit.RoomEventDispatcher
├── EVoiceKit.MediaSupervisor
│   ├── EVoiceKit.TrackForwarderSupervisor
│   ├── EVoiceKit.RetransmissionSupervisor
│   ├── EVoiceKit.MediaConsumerSupervisor
│   └── EVoiceKit.PacketWorkerPool
├── EVoiceKit.CompressionSupervisor
│   └── EVoiceKit.CompressionWorkerPool
├── EVoiceKit.SIPSupervisor
├── EVoiceKit.AgentSessionSupervisor
├── EVoiceKit.RecordingSupervisor
├── EVoiceKit.TaskSupervisor
├── Finch
└── Bandit
~~~

This is a logical proposal. Do not create each child until its ownership and state requirements are understood. One ExWebRTC PeerConnection already owns substantial internal state. Wrapping it in another GenServer is justified only when the wrapper gives a clear lifecycle/ownership boundary.

## 6.3 Process responsibility table

| Process/domain | Owns | Must not do |
|---|---|---|
| RoomCoordinator | Room lifecycle, participants, policy, events | Synchronous work for each RTP packet |
| ParticipantSession | Identity, grants, PeerConnection refs, state transitions | Decode all media or wait for AI provider |
| SignalingSession | WebSocket state, handshake, request correlation | Handle RTP UDP media as signaling frames |
| PeerConnectionOwner | ExWebRTC PC lifecycle and event delivery | Block on database or external AI HTTP calls |
| TrackRegistry | Track-to-owner mappings | Perform expensive per-packet database reads |
| SubscriptionManager | Subscription policy and graph updates | Route packets synchronously through room manager |
| TrackForwarder | Fast-path packet transformation/routing state | Own tenant authorization decisions without a control-plane grant |
| CompressionWorker | Bounded compression/decompression work | Accept unbounded input or unbounded output |
| AgentSession | Conversational turn state and AI tools | Own room lifecycle or direct WebRTC transport |
| SIP transaction/dialog process | SIP transaction/dialog timers and state | Assume SIP and RTP use same socket/port |
| Recording consumer | Recording buffers and storage lifecycle | Block publisher forwarding |

## 6.4 Ownership rules

Every dynamic process must have:
- One documented owner.
- A stable correlation ID.
- Start and stop APIs.
- Monitor/link policy.
- Restart policy.
- Timeout behavior.
- Cleanup path.
- Maximum resource policy.
- Telemetry for start, failure and termination.

A participant process crash must not terminate the room. A track-forwarder crash should be isolated to the tracks it owns if possible. A decompression job crash must not crash the room or the signaling supervisor.

## 6.5 Per-packet processing and mailbox safety

ExWebRTC PeerConnection emits messages to its controlling process. The documented v0.17 API includes messages for connection/ICE/DTLS changes, tracks, DataChannels, RTP and RTCP. The RTP event includes a track ID, optional simulcast RID and RTP packet; the RTCP event includes packet/track associations. The current ExWebRTC 0.18 package is the candidate dependency, so validate exact 0.18 API signatures before coding.

Reference API shape: https://hexdocs.pm/ex_webrtc/ExWebRTC.PeerConnection.html

The design must measure:
- Message rate per PeerConnection.
- PeerConnection owner mailbox length.
- Average and p99 packet handler duration.
- Scheduler utilization.
- Binary memory retained by process messages.
- Per-subscriber fan-out cost.
- Send queue growth.

Do not assume BEAM preemptive scheduling solves an overloaded media path. It limits a process's reduction slice; it does not make unlimited packet mailboxes safe.

## 6.6 Routing data structures

Candidate structures:
- ETS for read-mostly room/participant/track mapping where consistency requirements permit.
- Process state for authoritative room and PeerConnection ownership.
- Direct cached route references for active media paths.
- Versioned route updates when subscriptions change.
- Registry for locating owners, not as the per-packet policy database.

Every cached route needs invalidation on track unpublish, participant disconnect, room close, permission revocation or PeerConnection restart.

## 6.7 Avoiding GenServer.call in packet paths

Use asynchronous event or send paths for packet data. Avoid:
- Per-packet call to RoomCoordinator.
- Per-packet database lookup.
- Synchronous Redis lookup.
- Synchronous STT/TTS call from a PeerConnection owner.
- A global lock or global serialization point per room.

Control-plane changes can update fast-path route state. The media path then uses the installed route until a versioned update invalidates it.

---

# 7. Signaling protocol

## 7.1 Protocol requirements

The native protocol should define:
- Protocol name and version.
- Bootstrap framing.
- Message envelope and message-type registry.
- Request/response correlation.
- Event delivery semantics.
- Error code registry.
- Idempotency and retry behavior.
- Authentication context.
- Compression negotiation.
- Maximum message sizes.
- Reconnect and resynchronization.
- Backward and forward compatibility rules.
- Client capability vocabulary.

## 7.2 Transport

- HTTPS for ticket issuance and management APIs.
- WSS for signaling.
- Binary WebSocket frames after the initial bootstrap.
- RTP/SRTP media transported over WebRTC, not WebSocket.
- DataChannels as separate WebRTC transports.

Disable WebSocket permessage-deflate for the native endpoint if the custom application compression envelope is enabled. Running two compression systems on the same messages increases complexity and may double-compress or produce unexpected behavior.

## 7.3 Bootstrap messages

The initial bootstrap must be decodable before the compression algorithm is chosen.

Proposed sequence:

~~~text
Client                         Server
  |                              |
  |---- HTTP WSS upgrade -------->|
  |                              |
  |---- ClientHello (plain) ----->|
  |<--- ServerHello (plain) ------|
  |---- ClientReady (plain) ----->|
  |<--- ServerReady (plain) ------|
  |                              |
  |==== negotiated mode active ==|
  |                              |
  |---- JoinRoom ---------------->|
  |<--- JoinAccepted -------------|
  |---- SDP / ICE --------------->|
  |<--- SDP / ICE ----------------|
~~~

A server should queue application events while negotiation is pending. It must not send a compressed event before the client has confirmed the selected codec and mode.

## 7.4 ClientHello semantic schema

Illustrative Protocol Buffers shape, not a frozen schema:

~~~protobuf
message ClientHello {
  uint32 min_protocol_version = 1;
  uint32 max_protocol_version = 2;
  ClientIdentity client = 3;
  CompressionCapabilities compression = 4;
  MessageLimits limits = 5;
  WebRTCCapabilities webrtc = 6;
  repeated string features = 7;
  bytes client_nonce = 8;
}

message ClientIdentity {
  string sdk_name = 1;
  string sdk_version = 2;
  string platform = 3;
  string platform_version = 4;
  string runtime = 5;
}

message CompressionCapabilities {
  repeated CompressionAlgorithm encoders = 1;
  repeated CompressionAlgorithm decoders = 2;
  repeated CompressionProfile profiles = 3;
}

enum CompressionAlgorithm {
  COMPRESSION_NONE = 0;
  COMPRESSION_GZIP = 1;
  COMPRESSION_BROTLI = 2;
  COMPRESSION_ZSTD = 3;
}

message MessageLimits {
  uint32 max_wire_message_bytes = 1;
  uint32 max_plain_message_bytes = 2;
  uint32 max_data_channel_message_bytes = 3;
}

message WebRTCCapabilities {
  repeated string codecs = 1;
  repeated string header_extensions = 2;
  bool supports_simulcast = 3;
  bool supports_svc = 4;
  bool supports_data_channels = 5;
  uint32 max_data_channel_message_bytes = 6;
}
~~~

The actual schema should use package/versioning conventions and stable field numbers. Do not reassign protobuf field numbers after deployment; reserve removed fields.

## 7.5 ServerHello semantic schema

~~~protobuf
message ServerHello {
  uint32 selected_protocol_version = 1;
  CompressionSelection compression = 2;
  MessageLimits negotiated_limits = 3;
  WebRTCServerCapabilities webrtc = 4;
  bytes server_nonce = 5;
  bytes negotiation_id = 6;
  repeated string selected_features = 7;
}

message CompressionSelection {
  CompressionAlgorithm client_to_server = 1;
  CompressionAlgorithm server_to_client = 2;
  CompressionProfile client_to_server_profile = 3;
  CompressionProfile server_to_client_profile = 4;
  bool no_context_takeover = 5;
  uint32 min_compress_bytes = 6;
}

message CompressionProfile {
  int32 level = 1;
  uint32 max_window_bytes = 2;
}
~~~

Do not trust a client-supplied limit as an entitlement. The server must take the minimum of server configured limit, client-declared receive limit for that direction, product/tenant policy limit and hard protocol implementation limit.

## 7.6 Signaling request types

| Request | Purpose |
|---|---|
| ClientHello | Version and capability announcement |
| ClientReady | Confirms ServerHello and compression selection |
| JoinRoom | Join a named room using scoped credentials |
| LeaveRoom | Leave and release participant resources |
| PublishTrack | Announce track publication metadata |
| UnpublishTrack | End a published track |
| SubscribeTrack | Request track subscription |
| UnsubscribeTrack | Remove track subscription |
| SetTrackMuted | Change local published-track state |
| UpdateParticipant | Change permitted name/metadata/attributes |
| SetSubscriptionPermission | Grant/revoke subscription rights |
| Offer | SDP offer |
| Answer | SDP answer |
| TrickleCandidate | ICE candidate |
| RestartIce | Begin ICE restart |
| Reconnect | Resynchronize prior participant/room state |
| Ping | Application-level liveness |
| Pong | Ping response |
| GetStats | Request permitted diagnostics |
| Close | Graceful signaling close |

Server events:
- ServerHello.
- ServerReady.
- JoinAccepted.
- JoinRejected.
- ParticipantJoined.
- ParticipantLeft.
- ParticipantUpdated.
- TrackPublished.
- TrackUnpublished.
- TrackSubscribed.
- TrackUnsubscribed.
- TrackMuted.
- TrackUnmuted.
- SubscriptionChanged.
- Offer.
- Answer.
- TrickleCandidate.
- ConnectionQualityChanged.
- ActiveSpeakersChanged.
- RoomClosed.
- ServerError.
- Pong.
- ReconnectState.

## 7.7 Request correlation and ordering

Every request requiring a response should have:
- request_id.
- protocol_version.
- message_type.
- room/participant context where applicable.
- timeout budget.
- idempotency rule.

The server should reject:
- A request with a duplicate ID but different body when ID uniqueness is required.
- A request for a participant that does not belong to the authenticated connection.
- A state transition that is illegal in the current state.
- A message whose declared version is not negotiated.

Events should be ordered per signaling connection where order is semantically required. Do not claim global ordering across independent publishers or nodes unless a sequencer is implemented.

## 7.8 Unknown messages and compatibility

The schema must define:
- Whether unknown message types close the connection or return UNKNOWN_MESSAGE.
- Whether unknown protobuf fields are ignored.
- Minimum protocol version.
- Server deprecation window.
- Version negotiation failure.
- How new optional features are gated.
- Whether optional features can be used without changing the base protocol.

Never infer a feature from a client version string. Require explicit advertised capabilities and a server-side feature allowlist.

---

# 8. Connection bootstrap and authentication

## 8.1 Recommended ticket flow

1. An authenticated application backend calls POST /v1/connection-tickets.
2. The server validates tenant, user/service identity, room and requested grants.
3. The server creates a short-lived, one-time ticket.
4. The browser connects to WSS using the ticket.
5. Server validates signature, expiry, audience, nonce and one-time use.
6. Server binds the authenticated principal and permission set to the signaling session.
7. Only after successful validation can the connection join a room or allocate a PeerConnection.

## 8.2 Why use a ticket

Browser WebSocket APIs have restrictions on arbitrary request headers. Do not place long-lived API secrets or durable credentials in WebSocket query strings. A short-lived, single-use ticket can be used where browser constraints require URL transport, but it must be:
- Very short-lived.
- Single-use.
- Bound to the intended audience/endpoint.
- Redacted from access logs.
- Excluded from telemetry labels and traces.
- Invalidated after a successful redemption.

If secure cookie-based authentication is used, validate SameSite, Secure, HttpOnly and Origin behavior for the deployment.

## 8.3 Token claims

A signed room participant token should include equivalent claims to:
- issuer and key ID.
- subject / participant identity.
- tenant ID.
- audience.
- not-before.
- expiration.
- token ID / nonce.
- room grant.
- publish permission.
- subscribe permission.
- publish-data permission.
- participant metadata/attributes only where issued by a trusted backend.
- optional region or client-session binding where required.

Use a documented signing algorithm, key rotation procedure, clock skew policy and revocation strategy.

## 8.4 Authorization checks

Authorize independently:
- Room join.
- Publish audio.
- Publish video.
- Publish data.
- Subscribe to audio.
- Subscribe to video.
- Subscribe to data.
- Update self metadata.
- Update another participant.
- Mute another participant.
- Kick participant.
- Close room.
- Initiate SIP call.
- Create/assign AI agent.

Do not assume room membership implies permission to subscribe to every track.

## 8.5 Origin and CORS

- Verify browser Origin against an explicit allowlist.
- Reject null Origin by default unless a use case is approved.
- CORS is not authentication.
- Do not rely on wildcard CORS for authenticated signaling.
- Apply per-tenant origin policy where needed.
- Ensure reverse proxies preserve and forward the correct scheme/host headers safely.
- Reject invalid Host and forwarded headers according to deployment topology.

---

# 9. Compression capability negotiation

This section is a normative design proposal for the native protocol.

## 9.1 Three separate compression mechanisms

Do not conflate:

1. HTTP representation compression.
2. WebSocket per-message extensions.
3. E-Voice application-message compression.

HTTP response compression uses Accept-Encoding and Content-Encoding semantics.

The standardized WebSocket per-message compression extension is permessage-deflate (RFC 7692). Brotli and Zstandard are not automatically negotiated merely by including their names in WebSocket extension headers.

The native E-Voice protocol will use a custom application envelope over binary WebSocket messages. It will negotiate Brotli, gzip and Zstandard with a ClientHello/ServerHello exchange. This is not a new WebSocket extension.

References:
- https://www.rfc-editor.org/rfc/rfc7692.html
- https://developer.mozilla.org/en-US/docs/Web/API/CompressionStream/CompressionStream
- https://developer.mozilla.org/en-US/docs/Web/API/DecompressionStream/DecompressionStream

## 9.2 Directional negotiation

The client announces encoder and decoder capability separately.

- Client encoder = algorithms it can use to compress messages it sends.
- Client decoder = algorithms it can use to decompress messages it receives.
- Server encoder = algorithms the server can use to compress outbound messages.
- Server decoder = algorithms the server can use to decompress inbound messages.

Compute:
- Client-to-server intersection = client encoder set ∩ server decoder set.
- Server-to-client intersection = server encoder set ∩ client decoder set.

The server selects one algorithm per direction for V1. The server may select NONE even if compressed algorithms overlap, for example due to policy, a small message class or resource pressure.

Do not assume that a client is symmetric. A runtime might have a native decoder but no encoder, or the application may intentionally enable only one direction.

## 9.3 Mandatory baseline

NONE must always be available and implemented by every client and server.

If there is no shared compressed algorithm:
- Select NONE for that direction.
- Continue the session if the base protocol is compatible.
- Emit a capability metric.
- Do not fail a real-time call merely because compression is unavailable.

## 9.4 Algorithm registry

Initial native protocol identifiers:

| Numeric ID | Name | Stream/container semantics |
|---:|---|---|
| 0 | NONE | Original payload bytes |
| 1 | GZIP | gzip file/stream framing, RFC 1952 |
| 2 | BROTLI | Brotli compressed stream, RFC 7932 |
| 3 | ZSTD | Zstandard frame, RFC 8878 |

The Zstandard reference is RFC 8878, which replaces RFC 8478. RFC 8878 is informational, not an IETF Standards Track specification. Do not cite RFC 8478 as the current primary format reference.

References:
- https://www.rfc-editor.org/rfc/rfc1952.html
- https://www.rfc-editor.org/rfc/rfc7932.html
- https://www.rfc-editor.org/rfc/rfc8878.html

Do not confuse gzip wrapper with raw DEFLATE, zlib wrapper with raw DEFLATE, raw DEFLATE with Zstandard, or Zstandard frame with a transport-specific compression field.

## 9.5 Browser runtime support

The Compression Streams API exposes format names including gzip, Brotli and Zstandard, but algorithm-level support differs across runtimes.

At the MDN Browser Compatibility Data snapshot consulted during this research:
- gzip is broadly supported by current desktop/mobile browser engines.
- Brotli support is not universal across the major browser engines in the snapshot; Chrome's BCD entry reports no native support, Firefox lists a newer version and Safari lists support from 18.4.
- Zstandard support is considerably more limited; Chrome and Safari list no native support in the snapshot, while Firefox's entry is guarded by a preference/flag.
- The base CompressionStream API being supported does not imply every compression format is supported.

These facts can change. Client SDKs must probe the actual runtime, not trust this table forever.

For clients without native Brotli/Zstd:
- Use an audited WASM implementation, if the bundle/runtime policy allows it; or
- Use a platform-native codec on iOS/Android; or
- Advertise only gzip and NONE.

Do not advertise an algorithm simply because the protocol supports it.

Compatibility reference: https://github.com/mdn/browser-compat-data/blob/main/api/DecompressionStream.json. Native API references: https://developer.mozilla.org/en-US/docs/Web/API/CompressionStream/CompressionStream and https://developer.mozilla.org/en-US/docs/Web/API/DecompressionStream/DecompressionStream.

## 9.6 Runtime capability probing

For a browser client:
1. Check CompressionStream availability.
2. Check DecompressionStream availability.
3. Attempt construction for each algorithm independently.
4. Run a small deterministic round-trip test with a known sample.
5. Verify the decompressed output is byte-identical.
6. Enforce a local timeout and output cap.
7. Advertise the algorithm only if the actual implementation works.
8. If using WASM, wait until the module is loaded and initialized before advertising it.

Pseudocode:

~~~javascript
async function probeCodec(name) {
  try {
    const sample = new TextEncoder().encode("e-voice compression capability probe");
    const compressed = await transformWithCompressionStream(name, sample);
    const restored = await transformWithDecompressionStream(name, compressed);
    return bytesEqual(sample, restored);
  } catch {
    return false;
  }
}
~~~

This is illustrative pseudocode. The production SDK should use streaming reads with bounded output and should not buffer an unbounded stream.

## 9.7 Handshake sequence

Proposed states:

~~~text
NO_HELLO
  -> CLIENT_HELLO_VALIDATED
  -> SERVER_SELECTION_SENT
  -> CLIENT_SELECTION_ACKNOWLEDGED
  -> SERVER_READY_ACK_SENT
  -> COMPRESSION_ACTIVE
~~~

Detailed sequence:
1. WebSocket upgrade succeeds.
2. The first application message must be ClientHello and must be uncompressed.
3. Server checks version, algorithm identifiers, capability lists and client limits.
4. Server computes directional intersections and selection.
5. Server sends ServerHello uncompressed.
6. Client checks selected algorithms are in its advertised decoder/encoder lists.
7. Client sends ClientReady uncompressed.
8. Server validates ClientReady and sends ServerReady uncompressed.
9. Server transitions to COMPRESSION_ACTIVE only after ClientReady is validated.
10. Client transitions after receiving ServerReady.
11. Both directions use the agreed envelope after this point.

Queue server application events during negotiation. No data can overtake the final uncompressed readiness acknowledgement.

A protocol probe may be included before activation:
- Server sends a known compressed probe to prove client decoding.
- Client sends a known compressed probe to prove server decoding.
- The server records probe success/failure.
- No user secret or room metadata is included in probe content.

## 9.8 Negotiation rejection and fallback

| Condition | Required behavior |
|---|---|
| No common compression | Select NONE |
| Client has encoder but no decoder for algorithm | Use it only for client-to-server if intersection permits |
| Client has decoder but no encoder | Use it only for server-to-client if intersection permits |
| Unknown algorithm ID | Ignore optional unknown capability or reject unsupported required feature according to protocol version |
| Duplicate algorithm ID | Deduplicate deterministically or reject malformed hello |
| Client sends compressed before ready | Protocol violation; reject and close or downgrade only through explicitly versioned pre-negotiation rules |
| Client uses a different algorithm than selected | Reject frame and record a protocol error |
| Client reconnects with changed capability list | Negotiate again; old connection state is not reused |
| Compression library disabled by policy | Select NONE |
| Compression pool saturated | Per-message NONE only if negotiated as an allowed fallback policy; otherwise bounded queue/reject with explicit backpressure |

Do not silently downgrade to an algorithm that was not selected. The receiver must never guess the compression algorithm from payload bytes.

## 9.9 LiveKit wire compatibility

LiveKit's current RTC Protobuf defines NONE and GZIP for WrappedJoinRequest. Its current data-stream model separately defines NONE and DEFLATE_RAW, gated by client capability. That is not the same as the native E-Voice protocol proposed here.

If unmodified LiveKit SDK support becomes a requirement:
- Implement the LiveKit signaling schema and message semantics.
- Respect its protocol-version and capability gates.
- Use its actual compression fields/format.
- Do not substitute Brotli/Zstandard where the client expects gzip or raw DEFLATE.
- Run interoperability tests against official SDK versions.

References:
- https://github.com/livekit/protocol/blob/main/protobufs/livekit_rtc.proto
- https://github.com/livekit/protocol/blob/main/protobufs/livekit_models.proto
- https://docs.livekit.io/reference/internals/client-protocol/

---

# 10. Compression binary envelope and codec contracts

## 10.1 Design constraints

The envelope must be parseable before decompression, identify protocol/envelope version, identify message type and compression algorithm, state compressed wire payload length and declared uncompressed payload length, carry an optional request/correlation ID, define byte order and have strict reserved-bit behavior.

The exact layout is a proposal. It must be reviewed and frozen in an ADR before a public client SDK is released.

## 10.2 Proposed fixed 28-byte header

All integer fields use unsigned big-endian/network byte order unless explicitly stated.

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 4 | Magic | ASCII EVK1 |
| 4 | 1 | Envelope version | 1 for this header layout |
| 5 | 1 | Flags | Bit 0 compressed, bit 1 control; all other bits reserved |
| 6 | 1 | Algorithm ID | 0 NONE, 1 GZIP, 2 BROTLI, 3 ZSTD |
| 7 | 1 | Header length | 28 for V1 |
| 8 | 2 | Message type | Stable protocol message enum |
| 10 | 2 | Reserved | Must be zero in V1 |
| 12 | 4 | Wire payload length | Payload bytes following header |
| 16 | 4 | Plain payload length | Expected decoded bytes |
| 20 | 8 | Request/correlation ID | 0 when not applicable |
| 28 | N | Payload | Compressed or plain message body |

The WebSocket frame length must equal 28 + wire_payload_length. Any discrepancy is rejected before decompression.

For NONE:
- Algorithm ID = 0.
- Compressed flag = 0.
- Wire length must equal plain length.

For compressed:
- Algorithm ID must be one of the negotiated algorithms for that direction.
- Compressed flag = 1.
- The decoded payload must exactly match declared plain length.
- Trailing data or multiple compressed frames are rejected unless explicitly permitted by the codec profile.

## 10.3 Envelope validation order

1. Validate WebSocket frame type and configured frame size.
2. Require at least 28 bytes.
3. Validate magic.
4. Validate version.
5. Validate header length.
6. Validate reserved bytes and reserved flags.
7. Validate message type.
8. Validate algorithm ID.
9. Validate negotiated direction and algorithm.
10. Validate wire payload length against actual frame size.
11. Validate declared plain length against per-message hard cap.
12. Validate expansion ratio and per-tenant/connection budget.
13. Submit to bounded decoder.
14. Stream decoded chunks into a capped sink.
15. Check final output length equals declared plain length.
16. Parse the inner message only after successful decompression.
17. Validate inner request ID/type matches the outer header policy.
18. Dispatch into the current connection state machine.

Never allocate an output binary solely from an untrusted plain-length field without validating the maximum allowed size.

## 10.4 Message classes

| Class | Examples | Default compression policy |
|---|---|---|
| Bootstrap | ClientHello, ServerHello, ClientReady | Never compressed |
| Liveness | Ping, Pong | Never compressed |
| Small interactive control | Mute, unmute, track setting | Usually NONE due to small size |
| Signaling metadata | Participant metadata, room snapshots | Compress above threshold |
| SDP | Offer/answer | Compress only if benchmark proves benefit and message-size policy allows |
| Bulk application data | Larger structured payload, file metadata | Compress when profitable |
| DataChannel app payload | Arbitrary app messages | Negotiated separately/per stream; compress only if eligible |
| Media RTP/SRTP | Audio/video RTP | Never general-purpose compressed |
| RTCP/SRTCP | Feedback/control media packets | Never general-purpose compressed |

## 10.5 Compression selection policy

Selection is performed by direction, then policy can decide per message whether compression is useful.

Candidate initial policy:
- Zstandard level selected for low latency and tested against payload corpus.
- Brotli at a low/interactive quality profile for larger text-like payloads if it beats Zstd on the target CPU/network profile.
- gzip at a low compression level as a compatibility option.
- NONE for small messages and payloads which do not benefit.
- Never compress if the output is not smaller unless a measured CPU/network policy says otherwise.

Do not bake a single "Zstd always wins" assumption into the protocol. Selection must be based on measured compression time, decompression time, bytes saved, p99 signaling latency and total CPU.

## 10.6 Dictionaries and context takeover

V1:
- No cross-message context takeover.
- No shared rolling dictionary.
- No client-supplied dictionary.
- No opaque dictionary ID lookup.
- Each message is an independent compressed object/frame.

Reasons:
- Simpler failure isolation.
- No desynchronization after message loss/connection state error.
- Reduced state and memory retention.
- Easier fuzzing and test vectors.
- Lower risk of secrets becoming correlated with attacker-controlled input.
- Easier reconnect semantics.

A future version may define fixed, server-published dictionaries with IDs and cryptographic hashes, but only after a concrete benchmark shows material value and the security review approves it.

## 10.7 HTTP compression separation

HTTP endpoints should use their own HTTP compression pipeline:
- Parse Accept-Encoding.
- Choose a mutually supported response encoding.
- Set Content-Encoding.
- Set Vary: Accept-Encoding when caching semantics require it.
- Do not compress already-compressed media files without measured value.
- Do not reuse a WebSocket connection's negotiated algorithm for an unrelated HTTP request.

---

# 11. Compression implementation, safety and benchmarks

## 11.1 Elixir codec abstraction

Proposed behaviour:

~~~elixir
defmodule EVoiceKit.Compression.Codec do
  @type algorithm :: :none | :gzip | :brotli | :zstd
  @type options :: keyword()

  @callback algorithm() :: algorithm()
  @callback compress(binary(), options()) ::
              {:ok, binary()} | {:error, term()}
  @callback decompress(binary(), options()) ::
              {:ok, binary()} | {:error, term()}
  @callback decompress_stream(Enumerable.t(), options()) ::
              {:ok, Enumerable.t()} | {:error, term()}
end
~~~

This is a conceptual interface. The implementation should avoid collecting an unbounded stream into memory.

A separate policy layer should decide:
- Whether a message type is compressible.
- Whether it meets the size threshold.
- Which negotiated algorithm is selected.
- Which compression level/profile is used.
- Whether to return NONE because the compressed result is larger.
- Whether tenant/connection resource budgets allow the work.

## 11.2 Candidate server libraries

- Gzip: OTP :zlib APIs.
- Brotli: Erlang package brotli.
- Zstandard: Erlang package ezstd.

These are candidates, not unconditional dependency approvals. Verify the exact API, NIF implementation, incremental streaming behavior, output limits and maintenance status.

At the time of the researched package snapshot:
- Brotli package 0.3.4 fixes EEF-CVE-2026-111497, an out-of-bounds write in affected decoder versions >=0.3.0 and <0.3.4.
- ezstd 1.2.5 fixes CVE-2026-119434, a decompression-bomb/unbounded-output issue in affected versions >=1.0.5 and <1.2.5, specifically involving decompress_using_ddict/2.

Minimum version is not sufficient. The code must use a bounded decoding path, and future advisories must be monitored.

References:
- https://hex.pm/packages/brotli/advisories
- https://cna.erlef.org/cves/CVE-2026-111497.html
- https://hex.pm/packages/ezstd/advisories
- https://cna.erlef.org/cves/CVE-2026-119434.html

## 11.3 Decompression bomb defense

Apply multiple independent controls:
- Hard maximum wire payload length.
- Hard maximum decoded payload length.
- Maximum expansion ratio.
- Per-algorithm maximum window/memory settings.
- Per-message CPU/time budget.
- Per-connection decompression concurrency budget.
- Global worker pool capacity.
- Bounded task queue.
- Per-tenant byte and CPU budget.
- Maximum number of compressed messages per second.
- Early abort when output crosses the allowed limit.
- Strict final decoded-length equality.
- Metrics and structured error classification.

A ratio check alone is not sufficient. Some data expands substantially while remaining legitimate, and other hostile inputs may consume CPU/memory without violating a simple ratio threshold. Use absolute byte, time, memory and concurrency limits.

## 11.4 Native NIF scheduling

Compression can be CPU-intensive. Erlang's NIF documentation explains that work which cannot finish in roughly one millisecond should not run as an ordinary NIF on a normal scheduler; suitable work should be divided or scheduled on dirty CPU/I/O schedulers according to its behavior.

For every compression package:
- Inspect its NIF entry flags and native implementation.
- Determine whether large compression/decompression calls block normal schedulers.
- Test process termination during a long native call.
- Test native library error handling.
- Measure dirty scheduler saturation.
- Ensure CPU-bound operations are not misclassified as dirty I/O.
- Bound the number of concurrent native calls.

A Task.Supervisor does not automatically make a blocking NIF safe for normal BEAM schedulers. It supervises task processes; it does not change the scheduler class of an unsafe NIF.

Reference: https://www.erlang.org/doc/apps/erts/erl_nif.html

## 11.5 Compression worker behavior

Recommended worker contract:
- Input is a validated binary and immutable codec selection.
- Worker receives an absolute maximum output size.
- Worker reports compressed or decompressed bytes plus duration.
- Worker has a deadline/cancellation policy.
- Worker cannot mutate connection negotiation state.
- Worker never sends an application message unless the connection is still active and generation/epoch matches.
- Queue overflow is explicit.
- Worker crash is isolated.
- The connection owns a monotonically increasing generation number so late worker results from an old connection cannot be delivered after reconnect.

## 11.6 Compression benchmark suite

Payload corpus:
- ClientHello / ServerHello sizes.
- Typical signaling protobuf messages.
- Participant/room metadata.
- SDP offers and answers.
- Track and subscription snapshots.
- Text messages.
- Repetitive JSON/Protobuf payloads.
- Random/incompressible binary payloads.
- Large application data.
- Sanitized real signaling captures without tokens, PII or media.

Sizes:
- 128 bytes.
- 512 bytes.
- 1 KiB.
- 4 KiB.
- 16 KiB.
- 64 KiB.
- 256 KiB.
- 1 MiB.

Metrics:
- Compressed bytes / original bytes.
- Encode duration p50/p95/p99.
- Decode duration p50/p95/p99.
- CPU microseconds per MiB.
- BEAM reductions.
- Scheduler utilization.
- Dirty scheduler utilization.
- Peak memory.
- Binary memory retention.
- Worker pool queue wait.
- Throughput under concurrency.
- Effect on media packet processing jitter and signaling latency.

Test levels:
- gzip fast/default/high.
- Brotli fast/interactive and higher-ratio profile.
- Zstd fast and default levels.
- Native browser codecs and WASM fallbacks separately.

Use the compression policy only after the performance budget is demonstrated. Benchmark on representative server hardware and target client devices; desktop-only benchmarks are not sufficient.


---

# 12. WebRTC negotiation and PeerConnection lifecycle

## 12.1 ExWebRTC as the preferred building block

ExWebRTC is an implementation of the W3C WebRTC API in Elixir. Its README documents optional DataChannel support through ExSCTP and notes that ExSCTP requires Rust to compile. The candidate dependency is ExWebRTC 0.18.0.

The available API documentation during this research includes PeerConnection lifecycle, ICE candidate/state events, tracks, RTP/RTCP, DataChannels, statistics, transceivers and send APIs. Some references are from 0.17.0; exact 0.18.0 behavior must be validated before implementation.

References:
- https://github.com/elixir-webrtc/ex_webrtc
- https://hex.pm/packages/ex_webrtc/0.18.0
- https://hexdocs.pm/ex_webrtc/ExWebRTC.PeerConnection.html
- https://hex.pm/packages/ex_sctp

## 12.2 PeerConnection owner responsibilities

A server-side PeerConnection owner should:
- Create and configure the PeerConnection.
- Own its ICE configuration and ICE generation.
- Set local and remote session descriptions.
- Add remote ICE candidates.
- Receive ExWebRTC events.
- Notify signaling session of connection and candidate state.
- Register/unregister tracks.
- Route incoming RTP/RTCP events to the media plane.
- Send outgoing RTP on negotiated sender track IDs.
- Send relevant RTCP feedback.
- Close the PeerConnection on teardown.
- Export transport statistics and structured state transitions.

Do not hold a RoomCoordinator call open while performing SDP/ICE operations. Do not call external databases or AI providers from the PeerConnection event loop.

## 12.3 Separate state machines

Maintain separate state for:

**Signaling**
- awaiting_hello
- negotiating_capabilities
- authenticating
- joining_room
- awaiting_description
- stable
- reconnecting
- closing
- closed

**ICE**
- new
- checking
- connected
- completed
- disconnected
- failed
- closed

**DTLS**
- new
- connecting
- connected
- failed
- closed

**PeerConnection**
- new
- connecting
- connected
- disconnected
- failed
- closed

A WebSocket can be disconnected while the ICE/media path remains temporarily connected. ICE can be disconnected while WebSocket signaling is healthy. Do not collapse all of these into one state field.

## 12.4 Offer/answer and SDP state

Track:
- Local and remote session descriptions.
- Offerer/answerer role.
- Signaling state.
- ICE username fragment and password generation.
- MIDs and m-lines.
- Transceiver directions.
- Codec and fmtp negotiation.
- RTP feedback capabilities.
- Header extension mappings.
- BUNDLE groups and RTCP mux.
- DataChannel m-section and SCTP capabilities.
- Rejected media sections.
- Negotiation generation.

Reject invalid transitions with structured errors. Repeated or delayed SDP messages must not overwrite a newer negotiation.

## 12.5 Glare and renegotiation

Choose a deterministic negotiation policy for V1:
- Server-offerer for server-originated renegotiation; or
- Perfect-negotiation behavior, including explicit rollback handling, if supported by both client and server APIs.

Test:
- Both sides send offers simultaneously.
- Offer arrives while have-local-offer is active.
- Answer belongs to an old negotiation generation.
- Candidate belongs to an old ICE ufrag.
- Participant unpublishes while renegotiation is running.
- A new remote track arrives while signaling is not stable.
- Client reconnects while a server offer is pending.
- Track replacement happens while subscribers are active.

## 12.6 ExWebRTC send/receive API validation

The v0.17 PeerConnection docs describe RTP events with a track ID, optional RID and RTP packet; RTCP events with packets and track associations; and APIs such as send_rtp, send_pli, get_stats and get_twcc_departure_log. The docs state that send_rtp maps/overwrites payload type, SSRC and header extensions according to the sending transceiver/track mapping, and has an RTX option.

This is a key architectural input but not a guarantee for ExWebRTC 0.18.0. The Phase 0 spike must establish:
- What happens to sequence numbers and timestamps.
- Which RTP fields are overwritten.
- Which extension URIs are remapped.
- Whether the outgoing path handles TWCC accounting.
- How RTX packets are constructed.
- How RTCP feedback is delivered and associated with the correct track.
- Whether the media sender API can accept the required packet form without decoding.

Never build the SFU around an assumed API signature that has not been tested against the locked dependency version.

---

# 13. ICE, STUN, TURN and NAT traversal

## 13.1 ICE purpose and roles

ICE gathers local candidates, receives remote candidates, forms candidate pairs, checks connectivity and nominates a selected pair. Controlling and controlled roles participate in nomination and conflict resolution.

Use the implementation supplied by ExWebRTC and its dependencies. Do not implement STUN connectivity checks or ICE authentication from scratch.

Reference: RFC 8445 — https://www.rfc-editor.org/rfc/rfc8445.html

## 13.2 Candidate types

Support and test:
- Host candidates.
- Server-reflexive candidates.
- Peer-reflexive candidates.
- Relay candidates.

A client may not be able to reach the server through a host or server-reflexive candidate. The selected pair can use a TURN relay even when other candidates exist.

## 13.3 Candidate limits

Set configurable limits for:
- Remote candidates per PeerConnection.
- Candidate pairs/checklist size.
- Candidate string length.
- Candidate messages per second.
- Concurrent connectivity checks.
- Pending candidates before remote description.
- ICE restart frequency.
- Candidate retention per negotiation generation.

Reject or ignore duplicates according to a deterministic rule. A remote peer must not be able to grow candidate state without bound.

## 13.4 Trickle ICE

Trickle ICE allows candidates to arrive incrementally. Handle:
- Candidate arrives before remote description.
- Candidate arrives after end-of-candidates.
- Duplicate candidate.
- Stale ICE ufrag after restart.
- Candidate arrives for the wrong PeerConnection.
- Candidate has unsupported address family.
- Malformed candidate.
- Candidate flood.
- Signaling reconnect replays candidates.
- Candidate message arrives after PeerConnection teardown.

Queue pre-description candidates only within strict count/byte/time bounds; otherwise reject with a state-specific error.

Reference: RFC 8838 — https://www.rfc-editor.org/rfc/rfc8838.html

## 13.5 TURN

Use Coturn initially rather than building TURN in the first server milestones.

Deployment should support:
- STUN discovery.
- TURN over UDP.
- TURN over TCP.
- TURN over TLS where required by restrictive networks.
- Short-lived authenticated credentials.
- IPv4 and IPv6.
- Configured relay port ranges.
- Relay-only client tests.
- Allocation quotas and monitoring.

Reference: https://github.com/coturn/coturn

## 13.6 ICE restart and network changes

Distinguish:
- Signaling reconnect only.
- ICE restart on an existing PeerConnection.
- Full PeerConnection replacement.
- Logical participant reattachment.
- A new participant using the same application identity but a new session generation.

Use an ICE generation identifier so stale candidates cannot affect a restarted transport. Test Wi-Fi-to-cellular handoff, NAT rebinding, VPN changes and temporary UDP failure.

---

# 14. DTLS, SRTP and transport security

## 14.1 WebRTC security baseline

WebRTC media must use secure RTP and secure RTCP. DTLS-SRTP establishes keys; DataChannels are protected by DTLS. Plain unencrypted RTP/RTCP is not acceptable for the WebRTC endpoint.

References:
- RFC 8827 — https://www.rfc-editor.org/rfc/rfc8827.html
- RFC 5764 — https://www.rfc-editor.org/rfc/rfc5764.html
- RFC 8835 — https://www.rfc-editor.org/rfc/rfc8835.html

## 14.2 Server requirements

- Validate SDP fingerprints.
- Validate DTLS role and state.
- Enforce handshake timeouts.
- Reject failed or invalid security associations.
- Protect SRTP and SRTCP.
- Do not expose keys, private material or ICE passwords in logs/API responses.
- Release security associations on transport teardown.
- Test DTLS failure during negotiation and after reconnection.
- Test ICE restart behavior with DTLS state.
- Handle replay/authentication failure as a security/transport event.

## 14.3 Security boundary in an SFU

Each participant has an independent security association. The server decrypts/authenticates inbound SRTP and protects outbound SRTP for each subscriber. A publisher's encrypted SRTP datagram cannot simply be copied to all receivers because each egress transport has its own keys, SSRC/PT/header-extension mapping and packet state.

The server therefore terminates WebRTC transport security. This is not an end-to-end encrypted SFU architecture. If end-to-end media encryption is later required, it needs a separate design such as encoded-frame encryption with key distribution and SFU-visible routing metadata, plus a security analysis.

## 14.4 WSS and TLS

- Require HTTPS/WSS in production.
- Define TLS termination at the proxy or application.
- Do not trust forwarded host/scheme headers from arbitrary clients.
- Redact query tickets and credentials from access logs.
- Set explicit websocket idle/connection limits.
- Use certificate rotation and expiry monitoring.
- Restrict management/metrics endpoints to trusted networks.

---

# 15. RTP packet model and packet-processing requirements

## 15.1 Fixed RTP header

The fixed RTP header is 12 bytes:
- V: version.
- P: padding bit.
- X: extension bit.
- CC: CSRC count.
- M: marker bit.
- PT: payload type.
- Sequence number: 16 bits.
- Timestamp: 32 bits.
- SSRC: 32 bits.
- Optional CSRC list.
- Optional header extension.
- Payload.
- Optional padding.

Reference: RFC 3550 — https://www.rfc-editor.org/rfc/rfc3550.html

## 15.2 Parser validation order

A parser should:
1. Verify minimum packet length.
2. Require RTP version 2.
3. Parse CC and ensure enough CSRC bytes remain.
4. If X is set, parse extension profile and extension word count.
5. Validate extension length and boundaries.
6. Safely skip or parse unknown extension profiles.
7. Validate payload boundaries.
8. If P is set, validate the final padding count and exclude padding from payload.
9. Preserve marker, PT, sequence, timestamp and SSRC.
10. Avoid copying the payload where the language/API permits a safe sub-binary view.
11. Return a typed error for malformed structures instead of raising.

RFC 8285 defines one-byte and two-byte RTP header extension formats. Extension IDs are negotiated locally per transport and mapped to semantic URIs.

Reference: https://www.rfc-editor.org/rfc/rfc8285.html

## 15.3 Payload types are per negotiated media session

Do not hard-code:
- Opus to one global PT.
- VP8/H.264 dynamic payload types as fixed values.
- RTX PT as fixed globally.
- SIP payload type mapping as a WebRTC payload type mapping.

Maintain codec/PT/fmtp mapping per PeerConnection transceiver/track. Validate codec parameters and compatibility before forwarding.

## 15.4 SSRC mapping

Maintain explicit associations:
- Publisher SSRC -> UpTrack.
- Subscriber egress SSRC -> DownTrack.
- RTX SSRC -> DownTrack retransmission context.
- RID -> simulcast encoding.
- MID -> negotiated media section/track.

Detect collisions and handle changes. SSRC is not a participant identity. Streams may appear before signaling metadata fully identifies them; the mapping layer must have a bounded pending-track strategy.

## 15.5 Header extensions

For outgoing packets:
1. Parse extension IDs using the publisher's negotiated mapping.
2. Convert known IDs to semantic values.
3. Drop extensions that should not be shared.
4. Remap semantic values to subscriber negotiated extension IDs.
5. Recalculate extension profile/length.
6. Avoid copying publisher transport-specific sequence metadata unchanged.
7. Safely pass or remove unknown values according to policy.

Important extensions may include MID, RID, repaired RID, audio level, absolute send time, transport-wide sequence number and video dependency metadata. Feature support must be negotiated, not inferred from presence in an arbitrary packet.

---

# 16. SFU architecture and packet forwarding

## 16.1 Core components

**TrackRegistry**
- Maps participants and PeerConnections to tracks, MIDs, SSRCs and RIDs.
- Owns track publication state and generation.
- Provides fast lookup for active route state.

**UpTrack**
- Represents one incoming publisher track/encoding.
- Stores publisher, PeerConnection, track ID, MID/RID, codec, PT/SSRC, inbound statistics and last-seen state.

**DownTrack**
- Represents one subscriber-specific output stream.
- Stores subscriber PeerConnection, sender track ID, output SSRC/PT, sequence/timestamp mapping, extension map, RTX mapping, layer and queue state.

**SubscriptionManager**
- Owns subscription graph and authorization changes.
- Updates media routing state when subscriptions change.

**Router**
- Installs/removes UpTrack-to-DownTrack routes.
- Manages fan-out without blocking packet handlers.

**Forwarder**
- Performs bounded packet mapping and sends packets to destination PeerConnections.

## 16.2 Ingress algorithm

For every RTP event:
1. Identify PeerConnection owner.
2. Resolve track ID and optional RID.
3. Confirm the track is active and published.
4. Resolve UpTrack.
5. Update inbound counters/time.
6. Parse required RTP fields and extensions.
7. Obtain the current immutable or versioned DownTrack route set.
8. For each active DownTrack, map destination PT/SSRC/header extensions and sequence/timestamp as required.
9. Submit to that subscriber's bounded send path.
10. Update per-track/per-subscriber metrics.
11. Apply drop policy if queue capacity is exhausted.

Do not consult PostgreSQL, Redis or RoomCoordinator in this path.

## 16.3 SRTP termination and re-protection

The upstream WebRTC library handles ingress SRTP authentication/decryption and egress SRTP protection. The SFU forwards the RTP semantics/payload through the egress PeerConnection sender path. Do not forward raw encrypted UDP datagrams from the publisher to subscribers.

## 16.4 Destination-specific mapping

Potentially rewritten values:
- Payload type.
- SSRC.
- Sequence number.
- Timestamp offset.
- Marker semantics.
- MID/RID extension IDs.
- Repaired RID.
- Transport-wide congestion sequence value.
- RTX SSRC/PT/OSN.

The SFU must preserve codec payload data when compatible and avoid decode/re-encode on the normal path. Validate exactly what ExWebRTC rewrites on egress; do not double-rewrite fields already managed by the library.

## 16.5 Sequence and timestamp mapping

Maintain per-DownTrack state:
- Outbound sequence number and wraparound.
- Source and output SSRC.
- Timestamp base/offset.
- Source track generation.
- Last forwarded packet.
- Optional packet history mapping for NACK/RTX.

Sequence numbers wrap modulo 2^16. Timestamps wrap modulo 2^32. A track restart or source SSRC change must begin a new mapping generation.

Do not blindly renumber/re-time every packet unless required by the egress transport semantics. A mapping function must preserve media timing and packet ordering.

## 16.6 Fan-out and slow subscribers

One UpTrack may have many DownTracks. Requirements:
- Route set cached for fast access.
- Subscribe/unsubscribe updates applied without blocking ingress.
- Independent bounded egress queues.
- No head-of-line blocking across subscribers.
- No unbounded publisher buffering if there are no subscribers.
- Per-subscriber drop policy.
- Retransmission history bounded by time and bytes.
- Subscriber quality reduction under congestion.
- Clean route invalidation on track removal or permission changes.

A slow subscriber must not block the publisher or any other subscriber.

## 16.7 Late subscription

1. Authorize subscription.
2. Confirm source track and encoding are active.
3. Negotiate/update destination sender track.
4. Allocate DownTrack.
5. Install route.
6. Notify subscriber.
7. For video, request/await a decodable keyframe.
8. Begin normal forwarding.
9. Tear down if negotiation fails.

## 16.8 Track unpublish

1. Mark UpTrack unavailable.
2. Stop new packets from entering forwarding routes.
3. Remove route mappings.
4. Stop and clear DownTrack queues.
5. Remove retransmission history.
6. Notify subscribers.
7. Release decoders/recording consumers where unused.
8. Remove SSRC/RID/MID mappings.
9. Emit final stats and unpublish reason.

---

# 17. RTCP, retransmission and congestion control

## 17.1 Feedback and reports

Implement and test:
- Sender Reports.
- Receiver Reports.
- NACK.
- PLI.
- FIR where negotiated/supported.
- TWCC or other negotiated congestion feedback.
- RTCP mux.
- Feedback correlation to the correct PeerConnection/track.
- Per-subscriber counters.

RTCP is a media control path, not an optional logging feature.

## 17.2 NACK and retransmission

A subscriber asks for a missing packet using NACK. The SFU must:
1. Parse the feedback from the subscriber's RTCP path.
2. Resolve the affected DownTrack.
3. Map requested sequence numbers to its own send history.
4. Verify the packet remains within the retransmission time window.
5. Apply RTX if negotiated.
6. Build the correct retransmission packet, including original sequence number (OSN) where using RTX.
7. Send through the destination PeerConnection.
8. Record cache hit/miss and retransmit result.

Do not blindly forward a subscriber NACK to the publisher. The subscriber's sequence space may be translated and has its own history.

RFC 4588 defines the RTX payload format. The associated payload type is identified through the apt parameter; rtx-time may limit how long an original packet remains available for retransmission.

Reference: https://www.rfc-editor.org/rfc/rfc4588.html

## 17.3 PLI/FIR

- Resolve a request to source track and encoding.
- Aggregate requests from multiple subscribers.
- Apply per-track rate limits.
- Prefer requesting the correct simulcast layer.
- Record request-to-keyframe latency.
- Avoid a feedback amplification storm.

## 17.4 TWCC and per-transport feedback

Transport-wide sequence numbers and send-time accounting are scoped to a transport. Do not copy publisher TWCC values to subscriber packets unchanged. Egress PeerConnections need their own transport-wide accounting.

The selected ExWebRTC release must be tested for:
- Whether it generates outgoing transport sequence extensions.
- How departure time is recorded.
- Which RTCP feedback is emitted.
- How its sender statistics correlate with the SFU's own mappings.

## 17.5 Congestion control

Maintain separate estimates for each subscriber's egress path. A slow subscriber must not reduce quality for all other receivers.

Initial adaptation:
1. Preserve audio where possible.
2. Reduce video encoding/layer for the affected subscriber.
3. Stop sending layers the subscriber cannot sustain.
4. Drop stale queued video rather than delivering it too late.
5. Bound retransmission.
6. Pace packets.
7. Resume quality gradually.

Later add TWCC-based estimates, probing and more sophisticated layer selection after telemetry is established.

RTP itself does not provide congestion control. Real-time flows need congestion control and circuit-breaker behavior. References:
- RFC 8836: https://www.rfc-editor.org/rfc/rfc8836.html
- RFC 8083: https://www.rfc-editor.org/rfc/rfc8083.html
- RFC 8888: https://www.rfc-editor.org/rfc/rfc8888.html

---

# 18. Audio media

## 18.1 WebRTC audio

Primary initial WebRTC codec: Opus.

Important properties from RFC 7587:
- Opus uses a dynamic RTP payload type.
- RTP timestamp clock rate is 48,000 Hz for all Opus modes and input sampling rates.
- Timestamp is the sample time of the first encoded sample.
- Opus frame durations may be 2.5, 5, 10, 20, 40 or 60 ms, with further packetization possibilities.
- Receivers must be ready for duplicate RTP packets and deliver at most one copy of the duplicate payload to the decoder.

Reference: https://www.rfc-editor.org/rfc/rfc7587.html

Do not assume every Opus packet represents 20 ms of audio or that packet payload bytes map to a fixed size.

## 18.2 Telephony audio

Preserve existing G.711 PCMU/PCMA carrier integrations. Keep their transport contract separate from WebRTC.

Requirements:
- SDP-driven payload type mapping.
- Correct clock rate.
- RTP timestamp/sequence behavior.
- DTMF event handling.
- Optional transcoding to/from Opus.
- Explicit quality/latency cost for each transcode.

## 18.3 Generic AudioFrame

Proposed concept:

~~~elixir
defmodule EVoiceKit.Media.AudioFrame do
  defstruct [
    :payload,
    :encoding,
    :sample_rate,
    :clock_rate,
    :channels,
    :samples_per_channel,
    :timestamp,
    :duration,
    :track_sid,
    :participant_sid,
    :sequence,
    :source
  ]
end
~~~

Distinguish:
- Encoded bytes.
- Decoded PCM samples.
- RTP timestamp clock rate.
- PCM sample rate.
- Channel count.
- Frame duration.
- Source track/participant identity.

## 18.4 AI audio consumer

The STT/VAD path should be a separate consumer:
1. Subscribe to an allowed track.
2. Decode Opus/PCMU/PCMA where required.
3. Resample and convert channels/bit depth to the provider's requirements.
4. Apply voice activity/endpointing.
5. Stream bounded frames to STT.
6. Correlate transcript timestamps to source track.
7. Recover from provider disconnect.
8. Stop on subscription/agent shutdown.

The AI pipeline must not block normal SFU forwarding.

## 18.5 Agent output

TTS output should become an agent-published room track:
- Normalize generated audio.
- Encode to the negotiated output codec.
- Packetize with correct timestamps and sequence numbers.
- Publish through the agent PeerConnection/media interface.
- Track audio playout state.
- Stop/flush on barge-in.
- Use an output generation ID to discard late TTS chunks from an interrupted turn.

Do not send raw TTS bytes directly to a participant's signaling WebSocket as the new architecture's audio path.

## 18.6 Barge-in

The interruption path should:
- Detect new speech through VAD/STT/other detector.
- Increment a turn/output generation.
- Abort LLM/tool work according to cancellation policy.
- Abort TTS provider where supported.
- Flush local audio producer queues.
- Prevent late audio chunks from the previous generation from being published.
- Preserve the caller's inbound track.
- Record time from speech onset to silence of agent output.

Do not rely only on killing linked processes. Use explicit cancellation and generation checks.

---

# 19. Video media, simulcast and SVC

## 19.1 Initial codecs

Start with VP8 and H.264 only after the audio SFU is stable. Add VP9/AV1 after packetization, browser/mobile compatibility and resource usage are proven. Review H.264 distribution/licensing implications for the chosen implementation and distribution model.

## 19.2 Simulcast

Simulcast publishes multiple encodings of one source, often with different resolutions/bitrates. The SFU chooses an encoding for each subscriber.

Use negotiated RID and simulcast SDP semantics. References:
- RFC 8851: https://www.rfc-editor.org/rfc/rfc8851.html
- RFC 8853: https://www.rfc-editor.org/rfc/rfc8853.html

## 19.3 Layer selection

Per subscriber, maintain:
- Estimated downstream bitrate.
- Desired resolution/quality if known.
- Selected spatial/temporal layer.
- Current RID.
- Pending layer change.
- Keyframe readiness.
- Loss/jitter trend.
- Layer availability.

Never select a layer that is not published or negotiated. Apply changes only when the target encoding exists.

## 19.4 SVC

Scalable Video Coding needs codec-specific dependency knowledge. It is not equivalent to treating all RTP payloads as interchangeable bytes.

Gate SVC on:
- Negotiated codec/profile.
- Required dependency metadata/extensions.
- Correct layer filtering.
- Mobile/browser decoder interoperability.
- Tests for missing dependencies, packet loss and stream changes.

## 19.5 Keyframes

Handle:
- PLI/FIR aggregation.
- Keyframe arrival detection.
- New subscriber startup.
- Layer switch requiring keyframe.
- Publisher mute/unmute.
- Codec/format changes.
- Keyframe cache limits.
- Keyframe request rate limits.

---

# 20. WebRTC DataChannels

## 20.1 Transport model

WebRTC DataChannels use SCTP over DTLS over ICE. They support multiple streams and user messages that may be ordered or unordered, reliable or partially reliable. Stream reconfiguration is used to close channels. The SCTP stack has to support required partial reliability and stream reset extensions.

References:
- RFC 8831: https://www.rfc-editor.org/rfc/rfc8831.html
- RFC 8261: https://www.rfc-editor.org/rfc/rfc8261.html
- RFC 8841: https://www.rfc-editor.org/rfc/rfc8841.html
- RFC 8260: https://www.rfc-editor.org/rfc/rfc8260.html

## 20.2 Server relay model

The server terminates each participant's DTLS/SCTP association. It receives application messages from one association, applies room/track/topic authorization, and sends to destination associations. It does not simply forward encrypted SCTP datagrams from one browser to another.

The server therefore owns:
- Channel lifecycle.
- Stream ID mapping per peer.
- Authorization.
- Application message limits.
- Per-connection buffered data.
- Backpressure.
- Optional message compression envelope.

## 20.3 Channel profiles

Suggested logical profiles:

| Logical profile | Delivery semantics | Use |
|---|---|---|
| control | Reliable, ordered | Low-volume state changes |
| events | Reliable or unordered according to event type | Room/participant events |
| realtime | Unordered/partially reliable | Time-sensitive transient state |
| bulk | Reliable, flow-controlled | Larger payloads/files |

The exact SCTP channel configuration must be validated against ExSCTP and native SDK behavior.

## 20.4 Limits and failures

Bound:
- SCTP streams.
- Maximum message size.
- Reassembled message size.
- Buffered amount per channel.
- Bytes/sec per participant.
- Bytes/sec per room.
- Maximum reliable backlog.
- Idle channel time.
- Concurrent channels.
- Concurrent decompression.

Handle channel close during send, stream reset, association failure, unknown stream ID, oversized message, malformed envelope, partial reliability expiration and network interruption.

## 20.5 Compression on DataChannels

Use the compression capability vocabulary only when the channel's application protocol explicitly enables it. Apply an explicit per-message envelope. Respect maximum message size and ordering/reliability semantics. Do not general-purpose compress RTP media payloads.

---

# 21. Media processing, recording and egress

## 21.1 Media processing versus forwarding

Use a media pipeline only when a feature needs decoded frames/samples or a transformed output:
- Audio decode/resample.
- VAD.
- STT.
- Recording.
- Playback.
- Transcoding.
- Video frame transforms.
- Computer vision.
- Composite output.

Membrane is a candidate for these processing paths. Do not place it into every RTP forwarding operation without measurement and a concrete need.

References:
- https://github.com/membraneframework
- https://github.com/membraneframework/membrane_webrtc_plugin
- https://github.com/fishjam-cloud/membrane_rtc_engine (archived; architecture reference only)

## 21.2 Recording

Recording should be an independent consumer with:
- Room- or track-level policy.
- Audio-only and audio/video modes.
- Idempotent start/stop.
- Permission checks.
- Encryption at rest as required.
- Retention/deletion policy.
- Storage failure recovery.
- Metadata and audit trail.
- Bounded buffers.
- No blocking of the live forwarding path.
- Gap/drop accounting during overload.

## 21.3 Egress and composition

Recording original tracks, mixing audio, compositing video and generating HLS/MP4 are different workloads.

Mixing/compositing often requires decode/re-encode and needs separate CPU/memory limits. It must not share an unbounded queue with live RTP forwarding.

## 21.4 Ingress and transcoding

Support only explicit, negotiated adapters:
- SIP G.711 to AI PCM.
- File playback to room track.
- External RTP source to room track.
- Opus to PCM for STT.
- TTS PCM to Opus for WebRTC.

Record source codec, destination codec, conversion duration, bitrate and failure reason.

---

# 22. AI-agent participant architecture

## 22.1 Agent as participant

An AI agent joins the room with a server-issued service identity and scoped grants. It may:
- Subscribe to selected audio tracks.
- Publish TTS audio.
- Publish data/events.
- Receive room state/tool events.
- Mute its own output.
- Leave the room.

## 22.2 AgentSession ownership

AgentSession owns:
- Conversation/turn state.
- STT provider stream.
- LLM/BrainBridge.
- TTS provider stream.
- Tool execution state.
- Interruption generation.
- Agent configuration.

It does not own room lifecycle, PeerConnection transport security or global room authorization.

## 22.3 Multi-party policies

Explicitly configure:
- Which tracks are listened to.
- Whether each source is decoded separately or mixed.
- Whether diarization is needed.
- How participant identity/timestamps are passed to STT.
- How simultaneous speech is handled.
- Whether agent output is public to the room or privately routed.
- Whether recording and agent transcription are separate consumers.

Do not mix audio by default if the product needs speaker identity for diarization or audit.

---

# 23. SIP signaling and PSTN gateway

## 23.1 SIP architecture layers

Separate:
1. Transport: UDP/TCP/TLS socket lifecycle.
2. Parser/serializer: start line, headers, body and Content-Length.
3. Transaction layer: request/response state, retransmission timers and duplicate handling.
4. Dialog layer: Call-ID, tags, route set, CSeq and Contact.
5. User agent/call control: accept, reject, hold, transfer and terminate.
6. SDP: media address, formats, payload mapping, direction and security attributes.
7. RTP media endpoint: packet processing, RTCP and DTMF.
8. Room adapter: represent SIP call leg as participant/track.

RFC 3261 defines transaction state machines and timers. For an unreliable INVITE client transaction, Timer A starts at T1 and retransmission interval doubles; Timer B is 64*T1. Reliable transports have different retransmission behavior. These are protocol requirements, not arbitrary retry conventions.

Reference: https://www.rfc-editor.org/rfc/rfc3261.html

## 23.2 Initial SIP methods and scope

Minimum call flow:
- INVITE.
- 1xx provisional responses.
- 2xx final response.
- ACK.
- CANCEL.
- BYE.
- OPTIONS.

Additional scope only when required:
- REGISTER.
- INFO.
- UPDATE.
- REFER.
- PRACK.
- Session timers.
- Re-INVITE.

Do not claim registration, transfer or reliable provisional response support before its exact state machine and integration test exist.

## 23.3 Transactions and race conditions

Test:
- Retransmitted INVITE.
- Duplicate response.
- CANCEL racing with 200 OK.
- Late 200 OK after CANCEL.
- Multiple 2xx responses in forked INVITE.
- ACK matching correct dialog.
- BYE during re-INVITE.
- Timer expiry.
- Transport failure.
- Provisional response before final response.
- Response arriving after local timeout.
- TCP stream segmentation and multiple SIP messages per read.

Inject a controllable clock into SIP transaction timers to make tests deterministic.

## 23.4 SIP parsing

Production parser requirements:
- CRLF message framing.
- TCP stream segmentation.
- Compact header forms.
- Multiple headers where permitted.
- Correct Content-Length.
- URI parser.
- Quoted/escaped values.
- IPv4 and IPv6 literals.
- Header/body size limits.
- Header-count limit.
- Truncated message.
- Duplicate or ambiguous critical headers.
- Malformed start line.
- Invalid UTF-8/binary header behavior.

Do not parse the SIP grammar with a handful of regular expressions.

## 23.5 SDP offer/answer

Support:
- Session/media connection fields.
- Audio/video media lines.
- RTP profiles.
- rtpmap, fmtp and rtcp-fb.
- Direction attributes.
- RTCP mux.
- ICE ufrag/password/candidates as applicable.
- DTLS fingerprint/setup for secure media.
- MID.
- RID/simulcast.
- DTMF telephone-event.
- Hold/resume.
- Re-INVITE codec renegotiation.
- Rejected m-lines.

SDP is structured and has session-level/media-level inheritance. Do not assume first connection line and first audio line fully describe every media stream.

## 23.6 SIP RTP

- Use negotiated payload type and clock rate.
- Validate RTP header/payload.
- Handle sequence/timestamp wrap.
- Track SSRC and collisions.
- Reorder/buffer where playout or processing requires.
- Handle RTCP.
- Support symmetric RTP according to chosen security policy.
- Negotiate RFC 4733 telephone-event where supported.
- Use secure RTP profiles where required.
- Restrict accepted source address/port according to negotiated and learned media path.
- Protect against UDP packet floods and oversized datagrams.

## 23.7 SIP stack decision

Evaluate:
- NkSIP: https://github.com/erlnets/nksip
- ersip: https://github.com/poroh/ersip
- Parrot: https://github.com/byoungdale/parrot

Compare current maintenance, license, supported OTP, transport support, transaction/dialog behavior, SDP, TLS and interoperability tests. Do not select only from README feature claims.

---

# 24. Browser, mobile and native SDK requirements

## 24.1 Browser SDK

Illustrative public API:

~~~typescript
const client = new EVoiceClient({
  serverUrl,
  tokenProvider,
});

await client.connect();
const room = await client.joinRoom("support-room");
const localTrack = await client.publishMicrophone();

room.on("trackSubscribed", ({ participant, track }) => {
  // Attach the remote MediaStreamTrack to an audio/video element.
});

await client.disconnect();
~~~

Internal modules:
- WebSocket manager.
- Bootstrap handshake.
- Codec registry and capability probe.
- Binary envelope encoder/decoder.
- Room state reducer.
- PeerConnection adapter.
- SDP/ICE negotiation.
- Track publish/subscribe.
- Reconnection manager.
- DataChannel manager.
- Stats collector.
- Device manager.
- Structured error mapper.

Use a stable public API. Do not expose protobuf implementation types unless intentionally declared public.

## 24.2 Browser compression registry

Proposed codec contract:

~~~typescript
interface CompressionCodec {
  id: "none" | "gzip" | "brotli" | "zstd";
  canEncode(): Promise<boolean>;
  canDecode(): Promise<boolean>;
  encode(input: Uint8Array, limits: Limits): Promise<Uint8Array>;
  decode(input: Uint8Array, expectedLength: number, limits: Limits): Promise<Uint8Array>;
}
~~~

Provide native Compression Streams, approved WASM/native fallback and NONE adapters.

Probe encoder and decoder independently. Some browser runtimes expose the base API but not every algorithm. Do not advertise Brotli or Zstd unless the exact runtime can perform the required operation and pass a round-trip test.

## 24.3 iOS requirements

- AVAudioSession configuration.
- Microphone permission and denial.
- Bluetooth/HFP route changes.
- Headset insertion/removal.
- CallKit and system interruption behavior.
- Background audio behavior within platform rules.
- Network path changes.
- Camera/capture lifecycle.
- Thermal and battery considerations.
- Native Brotli/gzip/Zstd probing.
- Reconnect and ICE restart.
- App suspension/resume.

## 24.4 Android requirements

- RECORD_AUDIO permission lifecycle.
- Audio focus.
- AudioManager route changes.
- Bluetooth communication device behavior.
- Foreground service/background restrictions where applicable.
- Camera permission/lifecycle.
- Network callbacks and handover.
- Doze/battery behavior.
- Native codec libraries/ABI support.
- Reconnect and ICE restart.

## 24.5 React Native and Flutter

Prefer wrappers around a native WebRTC/media implementation. JavaScript/Dart should own product API and signaling state; native code owns capture/playout and OS audio lifecycle.

Test SDK versions against:
- Server protocol version.
- WebRTC library version.
- Codec list.
- Compression capability.
- DataChannel message limits.
- Supported iOS/Android OS versions.

---

# 25. Room APIs and control-plane operations

## 25.1 Proposed management routes

Names are proposals; freeze them in an API ADR.

| Method | Path | Purpose |
|---|---|---|
| POST | /v1/connection-tickets | Issue one-time signaling ticket |
| POST | /v1/rooms | Create room |
| GET | /v1/rooms/:room_sid | Get room metadata |
| POST | /v1/rooms/:room_sid/close | Close room |
| GET | /v1/rooms/:room_sid/participants | List participants |
| POST | /v1/rooms/:room_sid/participants/:id/remove | Remove participant |
| POST | /v1/rooms/:room_sid/participants/:id/permissions | Change grants |
| GET | /v1/rooms/:room_sid/tracks | List published tracks |
| POST | /v1/rooms/:room_sid/agents | Dispatch AI agent |
| GET | /v1/health/live | Process liveness |
| GET | /v1/health/ready | Dependency/readiness health |
| GET | /v1/metrics | Restricted metrics |

Admin APIs must not be directly exposed to untrusted browser clients. Use service-to-service credentials or scoped administrative grants.

## 25.2 Room configuration

A room should define:
- Tenant ID.
- Room SID/name.
- Empty-room timeout.
- Maximum participants.
- Maximum tracks per participant/room.
- Allowed media kinds.
- Allowed codecs/features.
- Recording policy.
- Metadata/attributes.
- Region/node policy.
- Origin/auth policy.
- Bandwidth/admission limits.

## 25.3 Room close semantics

Room close must:
1. Stop new joins.
2. Mark room as closing.
3. Notify participants.
4. Stop new publications/subscriptions.
5. Unpublish tracks.
6. Stop/leave AI agents according to policy.
7. Stop recording consumers.
8. Close PeerConnections.
9. Release room processes/timers/registries.
10. Persist final metadata if required.
11. Mark closed idempotently.

---

# 26. Data model and persistence boundaries

## 26.1 Durable state

PostgreSQL is suitable for:
- Tenants.
- User/service identities.
- API key metadata and key IDs.
- Room configuration.
- Agent definitions.
- SIP trunk configuration.
- Usage/billing records.
- Recording metadata.
- Audit records.

Do not store each RTP packet or packet-level event in PostgreSQL.

## 26.2 Ephemeral state

Keep hot state in OTP processes/ETS:
- Active rooms.
- Participants.
- PeerConnections.
- Tracks.
- Subscriptions.
- ICE/DTLS state references.
- Active speakers.
- Fast route mappings.
- Media queue state.
- Per-connection compression selection.

Persist events/metadata asynchronously only where durability requirements justify it.

## 26.3 Redis or equivalent

A future distributed deployment may use Redis for:
- Room owner lookup.
- Node leases and health.
- Cross-node control messages.
- Room allocation.
- Temporary reconnect state.
- Cluster signaling.

Redis is not a per-RTP-packet router.

## 26.4 Consistency

For every distributed object define:
- Authoritative owner.
- Lease/TTL.
- Epoch/version.
- Update ordering.
- Conflict resolution.
- Node failure behavior.
- Stale value cleanup.
- Reconnect behavior.

A stale owner record must not let two nodes both claim authoritative ownership of one room.

---

# 27. Distributed deployment and room placement

## 27.1 Single-node first

First release:
- Room owner is the local node.
- No Redis needed for media routing.
- Room remains on one server.
- PeerConnections are local.
- Media packets stay on local transport/forwarding processes.

## 27.2 Multi-node room affinity

Later:
1. Authenticate/create room request.
2. Select a healthy node based on capacity, region and tenant policy.
3. Create a room lease and ownership epoch.
4. Return/redirect the client to the room owner.
5. All participants for that room connect to the owner.
6. Relay control events only when needed.
7. Keep media local to the room owner in the normal path.

## 27.3 Node draining

- Mark node draining.
- Stop assigning new rooms.
- Stop joins to rooms selected for migration/reconnect.
- Notify clients according to recovery policy.
- Allow existing rooms to finish within the drain window.
- Close remaining resources safely.
- Release room leases.
- Flush telemetry.
- Report forced termination.

## 27.4 Node loss

If a room owner disappears:
- Detect node health/lease failure.
- Mark its rooms lost.
- Allow client reconnect.
- Reassign owner with a new epoch.
- Recreate room configuration and logical state.
- Participants rejoin and republish tracks.
- AI agents reconnect/restart according to policy.
- Recording gaps are recorded.
- Old owner epoch is rejected.

This is a reconnect/rejoin model, not transparent migration of live PeerConnections.

---

# 28. Backpressure, overload and graceful draining

## 28.1 Queue boundaries

Bound:
- Signaling mailbox.
- Per-participant event queue.
- Per-track forwarding queue.
- Per-subscriber send queue.
- Retransmission history.
- DataChannel buffered bytes.
- Compression worker queue.
- STT/TTS outbound queue.
- Recording/storage queue.
- SIP transaction queue.

## 28.2 Overload policy

| Resource | Policy |
|---|---|
| Signaling control queue | Reject/close abusive client with protocol error |
| Audio queue | Prefer bounded latency; drop stale frames instead of playing very late audio |
| Video queue | Drop stale frames/layers; preserve keyframe policy |
| RTCP feedback | Coalesce/aggregate safely; rate-limit storms |
| Compression queue | Bounded wait; NONE only if negotiated and explicitly allowed; otherwise reject/backpressure |
| DataChannel bulk queue | Enforce bufferedAmount/backpressure |
| Recording queue | Mark gaps/failure; never block live media |
| STT queue | Provider-specific restart/drop policy |
| SIP transaction queue | Admission control and SIP-appropriate failure |

## 28.3 Admission control

Before accepting a room/participant, consider:
- Node CPU and memory headroom.
- PeerConnection count.
- Estimated ingress/egress bitrate.
- Track count.
- Codec/transcoding workload.
- UDP socket/port capacity.
- TURN relay capacity.
- Compression worker availability.
- Recording and agent load.
- Tenant quotas.

Participant limits must be measurement-driven, not marketing assumptions.

## 28.4 Graceful shutdown

1. Mark node draining.
2. Reject new room creation.
3. Stop new participants joining selected rooms.
4. Notify clients.
5. Stop agents and recordings safely.
6. Close PeerConnections.
7. Close SIP transactions/dialogs according to policy.
8. Release leases/registries.
9. Flush telemetry.
10. Stop within a configured deadline.

---

# 29. Security and threat model

## 29.1 Assets

- API/signing keys.
- Tenant identity and room metadata.
- Participant identity and permissions.
- SDP/ICE credentials.
- DTLS/SRTP key material.
- Audio/video content.
- Recording files.
- Compression library/native memory.
- SIP credentials/trunks.
- Room ownership and route metadata.

## 29.2 Threat actors

- Unauthenticated Internet client.
- Authenticated but abusive tenant.
- Compromised client SDK.
- Malicious room participant.
- Malformed SDP/RTP/RTCP/SIP sender.
- Decompression-bomb sender.
- Slow subscriber attempting memory exhaustion.
- NACK/PLI/ICE candidate flooder.
- Cross-tenant room enumerator.
- Malicious/misconfigured TURN user.
- Compromised external provider key.

## 29.3 Required controls

### Signaling
- Authentication before expensive resource allocation.
- Origin validation.
- Message size/schema validation.
- Rate limits.
- State-machine enforcement.
- Token replay prevention.
- Tenant/room authorization.

### Media
- DTLS-SRTP.
- RTP/RTCP validation.
- Candidate/check rate limits.
- Track/bitrate admission.
- Subscription authorization.
- Queue bounds.
- Feedback flood prevention.

### Compression
- Patched packages.
- Bounded output and window.
- Expansion/time/concurrency limits.
- No untrusted dictionaries.
- No context takeover in V1.
- No secret + attacker-input shared compression context.
- Fuzzing.
- NIF crash/scheduler review.

### SIP
- Authentication policy.
- TLS where required.
- Source/media address validation.
- Transaction rate limits.
- Header/body size limits.
- Parser fuzzing.
- Call admission limits.
- Credential redaction.

### Storage
- Recording encryption.
- Retention/deletion.
- Tenant-scoped access.
- Signed expiring download links.
- Audit trail.

## 29.4 Compression side-channel policy

Do not compress:
- Access tokens.
- Session cookies.
- API keys.
- SIP credentials.
- Private room secrets.
- Messages that combine secret values and attacker-controlled text in the same compression context.

No-context-takeover and independent per-message streams reduce cross-message leakage but do not eliminate all side channels. The safest policy for secret-bearing messages is no compression.

---

# 30. Observability and operational diagnostics

## 30.1 Correlation identifiers

Use suitable identifiers in structured logs/traces:
- tenant_id.
- room_sid.
- participant_sid.
- peer_connection_id.
- track_sid.
- subscription_id.
- signaling connection ID.
- agent_session_id.
- sip_dialog_id.
- negotiation generation.
- room owner node ID.

Avoid high-cardinality IDs as metrics labels where they cause metrics cardinality explosion.

## 30.2 Connection metrics

- WSS upgrade success/failure.
- Ticket validation failure.
- Hello/negotiation duration.
- Compression selection.
- Room join/leave latency.
- SDP negotiation duration.
- ICE gathering/connection time.
- DTLS handshake time.
- Disconnect reason.
- Reconnect and ICE restart success.

## 30.3 Media metrics

- RTP packets/bytes in/out.
- Malformed packet count.
- Forwarded packet count.
- Per-track/subscriber loss/jitter/RTT.
- NACK/PLI/FIR rate.
- RTX hit/miss.
- Queue depth and drops.
- Audio/video bitrate.
- Selected video layer.
- Time since last packet.
- PeerConnection state.
- DataChannel open/close/buffered amount.

## 30.4 Compression metrics

- Algorithm selected per direction.
- Number of connections per algorithm.
- NONE fallback rate.
- Encode/decode duration p50/p95/p99.
- Compression ratio and bytes saved.
- CPU/memory.
- Worker queue depth.
- Malformed/corrupt payload count.
- Declared-length mismatch.
- Output-limit/ratio-limit failures.
- Native codec failures.

## 30.5 AI metrics

- STT startup.
- First partial/final transcript latency.
- LLM time to first token.
- TTS time to first audio.
- Barge-in stop latency.
- Decode queue duration.
- Agent join/reconnect.
- Provider failure rate.

## 30.6 Logging policy

Never log:
- Join tokens/tickets.
- API keys.
- SIP Authorization headers.
- ICE passwords.
- DTLS private keys.
- SRTP master keys.
- Raw audio/video.
- Sensitive participant metadata.

Use redacted structured errors.

---

# 31. Testing, interoperability and fault injection

## 31.1 Unit tests

Required:
- Compression envelope encode/decode.
- Codec round-trips and limits.
- RTP header parse/serialize.
- RTP extension parse/serialize.
- Sequence/timestamp mapping.
- SSRC collision.
- PT mapping.
- Track publication lifecycle.
- Subscription authorization.
- Room lifecycle.
- ICE generation checks.
- SDP parsing/normalization.
- SIP parser and URI parser.
- SIP transaction/dialog state.
- Agent cancellation/stale result suppression.
- Recording failure.

## 31.2 Property tests

Generate inputs for:
- RTP valid/invalid header combinations.
- Sequence and timestamp wraparound.
- CSRC count/length mismatch.
- Extension profiles and malformed lengths.
- Padding lengths.
- Compression envelopes/random lengths.
- Negotiation intersection/directional selection.
- Codec round-trip.
- SIP header parsing and Content-Length.
- SIP transaction timer order.
- Duplicate signaling requests.
- Room/participant/subscription invariants.

## 31.3 Fuzz targets

- ClientHello and ServerHello.
- Binary envelope.
- Protobuf decoding.
- SDP.
- ICE candidate parser.
- RTP.
- RTCP.
- SIP.
- SIP SDP body.
- Brotli/gzip/Zstd decoders.
- DataChannel message parser.

Fuzzers must run with memory/time limits. Native NIF fuzzing requires crash isolation.

## 31.4 Browser interoperability

Test Chromium, Firefox and WebKit/Safari on desktop and mobile-supported contexts. Test:
- SDP variations.
- Codec negotiation.
- ICE paths.
- TURN relay-only.
- DataChannels.
- Reconnect and ICE restart.
- Compression feature probes.
- Native and WASM codec adapters.
- Permission/device lifecycle.

A local two-browser test does not prove Internet-wide compatibility.

## 31.5 Network impairment

Inject:
- Latency.
- Jitter.
- Random and burst packet loss.
- Reordering.
- Duplication.
- Bandwidth caps.
- UDP block.
- TURN-only.
- Wi-Fi interruption.
- Cellular handoff.
- NAT mapping changes.
- Server queue saturation.

Record setup time and audible/video impact.

## 31.6 SIP interoperability

Use SIPp or equivalent and test against Asterisk, FreeSWITCH and at least one target carrier/PBX before production claims.

Cover INVITE retransmission, CANCEL race, 180/183, early media, 200/ACK, BYE, re-INVITE, hold/resume, DTMF, authentication, codec negotiation and NAT/symmetric RTP.

## 31.7 Load tests

Separate tests for:
- Concurrent WSS sessions.
- Concurrent PeerConnections.
- Audio-only rooms.
- Video rooms.
- Many publishers/one subscriber.
- One publisher/many subscribers.
- High fan-out.
- DataChannel throughput.
- Compression concurrency.
- SIP calls.
- Recording/egress.
- Agent/STT/TTS consumers.

Measure CPU, memory, process count, scheduler use, UDP drops, mailbox depth and latency percentiles. Publish measured limits, not theoretical process counts.

## 31.8 Fault injection

Inject:
- Participant process crash.
- PeerConnection owner crash.
- RoomCoordinator crash.
- TrackForwarder crash.
- Compression worker crash.
- NIF error/hang.
- STT/TTS disconnect.
- PostgreSQL unavailable.
- Redis unavailable.
- TURN unavailable.
- Node restart.
- Network partition.
- Recording storage failure.

Every test must specify expected blast radius and recovery.

---

# 32. Deployment reference

## 32.1 Initial deployment components

- E-Voice-Kit Elixir application.
- PostgreSQL for durable business/control data where used.
- Coturn.
- HTTPS/WSS reverse proxy/load balancer.
- Metrics/telemetry collection.
- Recording storage only when recording is enabled.

Future multi-node deployment adds multiple E-Voice media nodes and a control-plane coordination service.

## 32.2 Network ports

Document deployment-specific:
- HTTPS/WSS signaling port.
- WebRTC UDP range.
- STUN/TURN listener ports.
- TURN relay port range.
- SIP UDP/TCP/TLS ports.
- SIP RTP/RTCP range where enabled.
- Restricted management/metrics ports.

Do not assume an ephemeral UDP port opened inside Docker is reachable through NAT/firewall without an explicit configuration and test.

## 32.3 Reverse proxy

Ensure:
- WebSocket upgrade headers pass.
- Idle timeout supports long-lived signaling.
- Client IP forwarding trusts only configured proxies.
- TLS termination is explicit.
- Proxy buffering does not add latency.
- Body/frame size limits exist.
- Health/readiness endpoints are separated.
- Tickets/query secrets are redacted from logs.

## 32.4 Container build

Native dependencies may require:
- Rust for ExSCTP.
- C toolchain/headers for NIFs.
- Compatible target architecture/ABI.
- Runtime shared libraries in final image.

Use multi-stage build:
1. Build image with Erlang/Elixir/Rust/C toolchains.
2. Test image with full dependencies.
3. Release image with required runtime libs only.
4. Run a startup smoke test that loads all NIFs and initializes PeerConnection/DataChannel/compression capabilities.

## 32.5 Startup configuration

Validate:
- Bind addresses and ports.
- Public advertised address.
- UDP port range.
- ICE servers.
- TURN credentials.
- Room/participant/track limits.
- SDP and signaling message size.
- RTP/RTCP limits.
- Queue sizes.
- Compression algorithm enablement.
- Compression thresholds and worker limits.
- SIP transport/ports.
- Tenant default policy.
- Metrics endpoint access.
- Log redaction.

Missing production secrets must prevent secure production startup; never silently fall back to development passwords.

---

# 33. Proposed module map

Target organization, not a requirement to create all modules at once:

~~~text
lib/e_voice_kit/
├── application.ex
├── endpoint.ex
├── api/
│   ├── connection_tickets.ex
│   ├── rooms.ex
│   ├── participants.ex
│   └── health.ex
├── auth/
│   ├── token.ex
│   ├── grants.ex
│   ├── origin_policy.ex
│   └── ticket_store.ex
├── protocol/
│   ├── version.ex
│   ├── message.ex
│   ├── envelope.ex
│   ├── errors.ex
│   ├── signaling/
│   ├── protobuf/
│   └── compatibility/
├── compression/
│   ├── negotiation.ex
│   ├── capabilities.ex
│   ├── policy.ex
│   ├── envelope.ex
│   ├── worker.ex
│   ├── worker_pool.ex
│   └── codecs/
│       ├── none.ex
│       ├── gzip.ex
│       ├── brotli.ex
│       └── zstd.ex
├── signaling/
│   ├── websocket.ex
│   ├── session.ex
│   ├── dispatcher.ex
│   ├── request_registry.ex
│   └── reconnect.ex
├── rooms/
│   ├── room.ex
│   ├── room_supervisor.ex
│   ├── room_coordinator.ex
│   ├── registry.ex
│   └── events.ex
├── participants/
│   ├── participant.ex
│   ├── session.ex
│   ├── permissions.ex
│   └── lifecycle.ex
├── rtc/
│   ├── peer_connection_owner.ex
│   ├── peer_connection_supervisor.ex
│   ├── sdp.ex
│   ├── ice.ex
│   ├── dtls.ex
│   ├── transport_state.ex
│   └── stats.ex
├── sfu/
│   ├── router.ex
│   ├── track_registry.ex
│   ├── up_track.ex
│   ├── down_track.ex
│   ├── subscription.ex
│   ├── forwarder.ex
│   ├── packet_mapper.ex
│   ├── retransmission.ex
│   ├── congestion_control.ex
│   └── layer_selector.ex
├── media/
│   ├── frame.ex
│   ├── audio/
│   ├── video/
│   ├── codecs/
│   ├── consumers/
│   ├── recording/
│   └── egress/
├── data_channels/
│   ├── registry.ex
│   ├── relay.ex
│   ├── policy.ex
│   └── limits.ex
├── voice_ai/
│   ├── agent_session.ex
│   ├── participant.ex
│   ├── vad/
│   ├── stt/
│   └── tts/
├── sip/
│   ├── transport/
│   ├── parser.ex
│   ├── serializer.ex
│   ├── transaction.ex
│   ├── dialog.ex
│   ├── user_agent.ex
│   ├── sdp.ex
│   ├── rtp.ex
│   ├── dtmf.ex
│   └── room_adapter.ex
├── distributed/
│   ├── cluster.ex
│   ├── room_allocator.ex
│   ├── room_lease.ex
│   ├── node_health.ex
│   └── drain.ex
└── telemetry/
    ├── events.ex
    ├── metrics.ex
    └── redaction.ex
~~~

Existing carrier and AI provider modules remain and migrate gradually. Avoid a giant folder move before behavior is protected by tests.

---

# 34. Implementation sequence and engineering gates

## Gate 0 — Dependency and technical proof

Tasks:
- Verify ExWebRTC 0.18.0 against the actual Elixir/OTP build matrix.
- Establish a browser PeerConnection.
- Test SDP/ICE/DTLS.
- Receive RTP and RTCP.
- Send RTP using a sender track.
- Verify packet mapping and header rewrite.
- Test ExSCTP build and DataChannels.
- Verify native build in final Docker image.
- Test each compression library with fixed vectors.
- Verify bounded streaming decode.
- Verify NIF scheduler behavior.
- Run compression benchmark suite.
- Evaluate SIP dependencies.

Pass criteria:
- Browser-to-Elixir PeerConnection works.
- Server can receive and send a media packet using supported APIs.
- DataChannel feasibility/build path documented.
- Compression benchmark harness runs; all codec round trips pass.
- SIP recommendation is evidence-based.
- Known blockers and unsupported features recorded.

## Gate 1 — Signaling and compression handshake

Tasks:
- Implement versioned native signaling.
- Issue one-time connection tickets.
- Implement ClientHello/ServerHello/ClientReady/ServerReady.
- Implement directional algorithm selection.
- Implement binary envelope.
- Add NONE/gzip/Brotli/Zstd codecs.
- Add bounded worker/decompression limits.
- Add fallback handling.
- Fuzz envelope/codec paths.

Pass criteria:
- Browser and Elixir negotiate both directions.
- Malformed frames cannot crash server.
- NONE fallback works.
- Existing telephony endpoints remain unaffected.

## Gate 2 — Rooms, participants and tracks

Tasks:
- Room lifecycle.
- Participant supervision.
- PeerConnection ownership.
- Track registry.
- Publish/unpublish.
- Subscribe/unsubscribe.
- Permission enforcement.
- Cleanup/reconnect.

Pass criteria:
- Multiple browsers join one room.
- Join/publish/subscribe/leave are idempotent.
- Crashing one participant does not terminate room.

## Gate 3 — Audio SFU

Tasks:
- UpTrack/DownTrack.
- RTP packet forwarding.
- Destination PT/SSRC/extension mapping.
- Basic RTCP.
- Queue limits.
- Metrics.

Pass criteria:
- Two browsers exchange microphone audio through Elixir, without external SFU.
- Slow subscriber cannot block others.
- Publisher departure removes routes.
- Network impairment cases have tested outcomes.

## Gate 4 — Reliability and congestion control

Tasks:
- NACK/RTX.
- PLI/FIR.
- TWCC/congestion estimation.
- Backpressure.
- Subscriber bitrate policies.
- ICE restart/reconnect.
- Failure cleanup.
- Soak/load tests.

Pass criteria:
- Stable calls under defined packet loss/jitter/bandwidth constraints.
- No unbounded queue/memory growth.
- Latency/capacity baselines measured.

## Gate 5 — Video SFU

Tasks:
- VP8/H.264.
- Simulcast.
- SVC where supported.
- Keyframe management.
- Adaptive forwarding.
- Video queue policy.

Pass criteria:
- Multiple clients publish/subscribe video with layer adaptation and bounded resources.

## Gate 6 — DataChannels

Tasks:
- ExSCTP lifecycle.
- Reliable/unreliable channel profiles.
- Message limits and flow control.
- Compression for eligible application data.
- File/data streams if required.

Pass criteria:
- DataChannel interoperability passes.
- Compression selection/fallback/security tests pass.

## Gate 7 — AI and SIP

Tasks:
- AI agent participant.
- Audio decode/AI consumer.
- TTS output track.
- SIP stack selection and transaction/dialog.
- SIP/RTP room adapter.
- G.711/Opus interoperability.

Pass criteria:
- Browser, SIP and AI participants interact in a room.
- Existing carriers continue to pass regression tests.

## Gate 8 — Distributed production

Tasks:
- Node health and room placement.
- Room lease/epoch.
- Redis coordination if approved.
- Graceful drain.
- Reconnect after node loss.
- Recording/egress.
- Security review and SBOM.
- Capacity and cost benchmarks.

Pass criteria:
- Deployment, recovery, scaling, security and operations documented.
- Node-loss/reconnect tested.
- SLOs based on actual measurements.

---

# 35. Architecture decisions still requiring approval

These must become ADRs before protocol or implementation becomes difficult to change:

1. Native E-Voice protocol only, or unmodified LiveKit SDK compatibility as a release-one requirement?
2. One Unified Plan PeerConnection or separate publisher/subscriber PeerConnections in native mode?
3. Protobuf-only bootstrap, JSON bootstrap plus Protobuf, or another versioned format?
4. Exact binary envelope layout and message ID registry?
5. Directional algorithm selection only, or additional traffic-class profiles?
6. Native browser codecs only or audited WASM fallbacks for Brotli/Zstandard?
7. ExSCTP native build and release strategy?
8. Track/packet-forwarder process ownership after ExWebRTC 0.18 validation?
9. SIP stack: NkSIP, ersip integration, Parrot evaluation or bounded custom scope?
10. First video codecs and H.264 distribution/licensing constraints?
11. Recording format, storage and retention?
12. Redis/control-plane coordination model for multi-node?
13. Tenant quotas and default resource limits?
14. Compression thresholds, levels, limits and scheduler behavior after benchmarks?

---

# 36. Glossary

| Term | Meaning |
|---|---|
| API | Application Programming Interface |
| BEAM | Erlang virtual machine |
| DTLS | Datagram Transport Layer Security |
| ICE | Interactive Connectivity Establishment |
| MCU | Multipoint Control Unit; mixes/transforms media |
| MID | SDP media identifier |
| NIF | Native Implemented Function |
| OTP | Erlang/Elixir concurrency and supervision framework |
| PLI | Picture Loss Indication |
| PT | RTP payload type |
| RID | RTP Stream Identifier |
| RTP | Real-time Transport Protocol |
| RTCP | RTP Control Protocol |
| RTX | RTP retransmission |
| SDP | Session Description Protocol |
| SFU | Selective Forwarding Unit |
| SIP | Session Initiation Protocol |
| SRTP | Secure RTP |
| SRTCP | Secure RTCP |
| SSRC | Synchronization Source identifier |
| STUN | Session Traversal Utilities for NAT |
| SCTP | Stream Control Transmission Protocol |
| TURN | Traversal Using Relays around NAT |
| TWCC | Transport-Wide Congestion Control |
| WASM | WebAssembly |
| WSS | WebSocket over TLS |

---

# 37. Standards, upstream projects and source references

## 37.1 E-Voice-Kit source inspected

The technical design is based on the develop baseline:
- https://github.com/FLCN-16/e-voice-kit/blob/develop/mix.exs
- https://github.com/FLCN-16/e-voice-kit/blob/develop/README.md
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/application.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/endpoint.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/pipeline/session.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/pipeline/buffer.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/transports/sip_carrier.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/transports/sip/rtp.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/transports/sip/message.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/transports/websocket_carrier.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/providers/carrier.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/providers/stt.ex
- https://github.com/FLCN-16/e-voice-kit/blob/develop/lib/e_voice_kit/providers/tts.ex

## 37.2 ExWebRTC and Elixir media

- ExWebRTC: https://github.com/elixir-webrtc/ex_webrtc
- ExWebRTC 0.18.0: https://hex.pm/packages/ex_webrtc/0.18.0
- ExWebRTC dependencies: https://hex.pm/packages/ex_webrtc/0.18.0/dependencies
- ExWebRTC PeerConnection docs: https://hexdocs.pm/ex_webrtc/ExWebRTC.PeerConnection.html
- ExSCTP: https://hex.pm/packages/ex_sctp
- Membrane: https://github.com/membraneframework
- Membrane WebRTC plugin: https://github.com/membraneframework/membrane_webrtc_plugin
- Archived RTC Engine reference: https://github.com/fishjam-cloud/membrane_rtc_engine

## 37.3 LiveKit architecture and protocol

- LiveKit SFU architecture: https://docs.livekit.io/reference/internals/livekit-sfu/
- LiveKit client protocol: https://docs.livekit.io/reference/internals/client-protocol/
- LiveKit RTC Protobuf: https://github.com/livekit/protocol/blob/main/protobufs/livekit_rtc.proto
- LiveKit models Protobuf: https://github.com/livekit/protocol/blob/main/protobufs/livekit_models.proto

The inspected LiveKit protocol source currently shows:
- NONE and GZIP for WrappedJoinRequest compression.
- NONE and DEFLATE_RAW for DataStream CompressionType, with capability gating.

This is a compatibility reference only. It does not define the native E-Voice compression protocol.

## 37.4 WebRTC standards

- RFC 3550 — RTP: https://www.rfc-editor.org/rfc/rfc3550.html
- RFC 3551 — RTP profile for audio/video: https://www.rfc-editor.org/rfc/rfc3551.html
- RFC 4585 — RTP/AVPF feedback: https://www.rfc-editor.org/rfc/rfc4585.html
- RFC 4588 — RTP retransmission: https://www.rfc-editor.org/rfc/rfc4588.html
- RFC 8285 — RTP header extensions: https://www.rfc-editor.org/rfc/rfc8285.html
- RFC 8445 — ICE: https://www.rfc-editor.org/rfc/rfc8445.html
- RFC 8489 — STUN: https://www.rfc-editor.org/rfc/rfc8489.html
- RFC 8656 — TURN: https://www.rfc-editor.org/rfc/rfc8656.html
- RFC 8827 — WebRTC security architecture: https://www.rfc-editor.org/rfc/rfc8827.html
- RFC 8831 — WebRTC DataChannels: https://www.rfc-editor.org/rfc/rfc8831.html
- RFC 8834 — RTP media transport in WebRTC: https://www.rfc-editor.org/rfc/rfc8834.html
- RFC 8835 — WebRTC transports: https://www.rfc-editor.org/rfc/rfc8835.html
- RFC 8838 — Trickle ICE: https://www.rfc-editor.org/rfc/rfc8838.html
- RFC 8839 — SDP offer/answer for ICE: https://www.rfc-editor.org/rfc/rfc8839.html
- RFC 8841 — SDP SCTP DataChannel negotiation: https://www.rfc-editor.org/rfc/rfc8841.html
- RFC 8261 — SCTP over DTLS: https://www.rfc-editor.org/rfc/rfc8261.html
- RFC 8260 — SCTP message interleaving: https://www.rfc-editor.org/rfc/rfc8260.html
- RFC 7587 — Opus RTP payload: https://www.rfc-editor.org/rfc/rfc7587.html
- RFC 8851 — RID restrictions: https://www.rfc-editor.org/rfc/rfc8851.html
- RFC 8853 — Simulcast in SDP/RTP: https://www.rfc-editor.org/rfc/rfc8853.html
- RFC 8836 — Congestion control requirements: https://www.rfc-editor.org/rfc/rfc8836.html
- RFC 8083 — RTP circuit breakers: https://www.rfc-editor.org/rfc/rfc8083.html
- RFC 5764 — DTLS-SRTP: https://www.rfc-editor.org/rfc/rfc5764.html

## 37.5 Compression and runtime

- RFC 1952 — GZIP: https://www.rfc-editor.org/rfc/rfc1952.html
- RFC 7932 — Brotli: https://www.rfc-editor.org/rfc/rfc7932.html
- RFC 8878 — Zstandard: https://www.rfc-editor.org/rfc/rfc8878.html
- RFC 7692 — WebSocket permessage-deflate: https://www.rfc-editor.org/rfc/rfc7692.html
- MDN CompressionStream: https://developer.mozilla.org/en-US/docs/Web/API/CompressionStream/CompressionStream
- MDN DecompressionStream: https://developer.mozilla.org/en-US/docs/Web/API/DecompressionStream/DecompressionStream
- MDN browser compatibility data: https://github.com/mdn/browser-compat-data
- Erlang NIF documentation: https://www.erlang.org/doc/apps/erts/erl_nif.html
- Erlang zlib documentation: https://www.erlang.org/doc/apps/erts/zlib.html
- Brotli Hex package/advisories: https://hex.pm/packages/brotli
- Zstandard Hex package/advisories: https://hex.pm/packages/ezstd

## 37.6 SIP

- RFC 3261 — SIP: https://www.rfc-editor.org/rfc/rfc3261.html
- RFC 3264 — SDP Offer/Answer: https://www.rfc-editor.org/rfc/rfc3264.html
- RFC 4733 — RTP DTMF events: https://www.rfc-editor.org/rfc/rfc4733.html
- NkSIP: https://github.com/erlnets/nksip
- ersip: https://github.com/poroh/ersip
- Parrot: https://github.com/byoungdale/parrot
- Coturn: https://github.com/coturn/coturn

---

## Final engineering note

This document is the detailed technical companion to the implementation roadmap. It deliberately identifies existing repository behavior, upstream protocol requirements, proposed E-Voice architecture and unresolved decisions separately.

The architecture should be implemented incrementally. The first proof must establish that ExWebRTC 0.18.0 can be used safely in the actual E-Voice-Kit runtime and that the application can receive and forward audio RTP between two browser clients. Compression must be independently benchmarked and security-tested. SIP and multi-node deployment must remain separate gated workstreams.

No item in this document should be marked implemented until code, automated tests, interoperability evidence and operational measurements support that claim.
