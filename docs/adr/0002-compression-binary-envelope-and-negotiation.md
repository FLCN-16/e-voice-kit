# ADR-0002: 28-Byte Binary Envelope & Directional Compression Negotiation

## Status
**ACCEPTED** (2026-11-20)

## Context
Section 7 of [ELIXIR_REALTIME_SERVER_PLAN.md](../ELIXIR_REALTIME_SERVER_PLAN.md) and Sections 9 & 10 of [ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md](../ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md) require negotiated application-message compression over WebSocket and DataChannels using Brotli, gzip, and Zstandard. 

Key constraints:
- Standard WebSocket compression (RFC 7692 `permessage-deflate`) does not support Brotli or Zstandard and operates at the transport frame layer.
- General-purpose compression must never be applied to already compressed or real-time media (RTP, SRTP, RTCP, Opus, VP8/H.264).
- Safe decompression requires pre-validation of headers, bounding wire payload lengths, plain payload lengths, expansion ratios, and memory/CPU limits to prevent decompression bombs.

## Decision
1. **Application-Layer Envelope:** We will implement application-envelope compression at the binary payload level. Standard WebSocket `permessage-deflate` will be disabled on the native signaling endpoint to eliminate redundant double compression.
2. **Fixed 28-Byte Binary Header Layout (`EVK1`):**
   All integer fields are unsigned big-endian (network byte order).
   ```text
   | Offset | Size | Field                | Type / Meaning                                  |
   |-------:|-----:|----------------------|-------------------------------------------------|
   |      0 |    4 | Magic                | ASCII 'EVK1' (0x45, 0x56, 0x4B, 0x31)           |
   |      4 |    1 | Envelope Version     | 1                                               |
   |      5 |    1 | Flags                | Bit 0: compressed (1) or uncompressed (0)       |
   |        |      |                      | Bit 1: control frame (1) or data (0)            |
   |        |      |                      | Bits 2-7: reserved (must be 0)                  |
   |      6 |    1 | Algorithm ID         | 0: NONE, 1: GZIP, 2: BROTLI, 3: ZSTD            |
   |      7 |    1 | Header Length        | 28 (bytes)                                      |
   |      8 |    2 | Message Type         | 16-bit enum (Signaling/RTC message code)        |
   |     10 |    2 | Reserved             | 0x0000 (must be zero in V1)                     |
   |     12 |    4 | Wire Payload Length  | Length in bytes of the following payload        |
   |     16 |    4 | Plain Payload Length | Expected uncompressed size in bytes             |
   |     20 |    8 | Request/Corr ID      | 64-bit correlation ID (0 if not applicable)     |
   |     28 |    N | Payload              | Payload bytes (compressed or plain)             |
   ```
3. **Directional Capability Negotiation:**
   - Signaling begins with an uncompressed `ClientHello` and responds with an uncompressed `ServerHello`.
   - Compression is negotiated independently per direction:
     - Client -> Server: `client_encoders ∩ server_decoders`
     - Server -> Client: `server_encoders ∩ client_decoders`
   - `NONE` (algorithm ID 0) is mandatory fallback for both endpoints.
4. **Safety & Decompression Guardrails:**
   - Wire size check: `total_frame_size == 28 + wire_payload_length`.
   - Max plain payload size hard cap: default 2 MiB (configurable per tenant).
   - Max compression expansion ratio: default 15:1.
   - Streaming/chunked decompression into bounded sinks; reject immediately on limit breach.
   - No context takeover across messages in V1 (stateless per-message compression).

## Consequences
- **Positive:** Unambiguous, high-performance binary framing with zero guesswork on algorithm types.
- **Positive:** Immune to decompression bombs and memory exhaustion attacks via strict length pre-checks.
- **Positive:** Clear separation of control signaling from WebRTC SRTP media.
- **Negative:** Requires custom binary parser in client SDKs.
- **Mitigation:** The 28-byte parser is trivial to implement in JavaScript (DataView), Swift, Kotlin, and Rust.
