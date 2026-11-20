# ADR-0008: Track & Packet-Forwarder Process Ownership

## Status
**ACCEPTED** (2026-11-20)

## Context
RTP packet forwarding is latency-sensitive. Routing thousands of media packets through a central room GenServer creates severe mailbox queues and serialization bottlenecks.

## Decision
1. **Asynchronous Fast-Path:** The `RoomCoordinator` acts solely as a control-plane authority. It installs routing rules in `EVoiceKit.SFU.Router`.
2. **Direct Dispatch:** Incoming media packets from an `UpTrack` are rewritten by `EVoiceKit.SFU.PacketMapper` and dispatched asynchronously (`send/2`) to subscriber sink processes (`DownTrack.sink_pid`).
3. **Non-Blocking Forwarding:** Slow subscribers or full message queues result in subscriber-specific packet drops; the publisher and other room subscribers are never blocked.

## Consequences
- **Positive:** Bounded low latency (< 10 ms forwarding overhead) even under high subscriber counts.
