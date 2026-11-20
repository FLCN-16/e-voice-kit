# ADR-0012: Multi-Node Room Placement & Redis Coordination

## Status
**ACCEPTED** (2026-11-20)

## Context
Scaling beyond a single media server requires distributing rooms across nodes while keeping media packet routing local.

## Decision
1. **Single-Node Authoritative Room Owner:** Each room is owned by exactly one media server node. All participants in a room connect directly to that node.
2. **Distributed Metadata:** Redis or Erlang Distributed PG is used only for room allocation, node heartbeats, and room-to-node routing leases.
3. **No Inter-Node Packet Forwarding in V1:** RTP media packets are never routed through Redis or external message brokers.

## Consequences
- **Positive:** Preserves sub-10ms packet forwarding latency and eliminates complex inter-node media synchronization in early phases.
