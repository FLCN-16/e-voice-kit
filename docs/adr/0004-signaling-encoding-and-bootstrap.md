# ADR-0004: Signaling Encoding & Bootstrap Handshake

## Status
**ACCEPTED** (2026-11-20)

## Context
Signaling requires a clear, unambiguous bootstrap sequence before connection authentication and compression activation. Conflating pre-negotiation framing with post-negotiation payloads creates parsing ambiguities and security risks.

## Decision
1. **Uncompressed Bootstrap:** The signaling connection strictly begins with an uncompressed `ClientHello` and server `ServerHello`. Pre-negotiation frames must have `algorithm_id = 0` (`NONE`) and `compressed = 0`.
2. **Payload Serialization:** JSON encoding is used for the bootstrap handshake and control frames in V1, wrapped within the fixed 28-byte `EVK1` binary envelope. Binary Protobuf schemas may be layered inside the envelope for high-frequency participant metadata in V2.
3. **Correlation:** Every request carries a 64-bit unsigned `request_id` in the binary envelope to correlate asynchronous responses without head-of-line blocking.

## Consequences
- **Positive:** Zero protocol ambiguity during connection initialization; predictable client parsing across all web browsers and mobile platforms.
