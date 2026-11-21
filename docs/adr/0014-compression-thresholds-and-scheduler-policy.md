# ADR-0014: Compression Thresholds & BEAM Scheduler Budgets

## Status
**ACCEPTED** (2026-11-20)

## Context
Running CPU-intensive compression algorithms inside native Erlang NIFs can monopolize BEAM schedulers and degrade media packet forwarding latency.

## Decision
1. **Dirty Schedulers:** Native NIF compression/decompression calls taking longer than 1 ms must execute on dirty CPU schedulers (`ERL_NIF_DIRTY_JOB_CPU_BOUND`).
2. **Size Threshold:** Small payloads (< 256 bytes) bypass compression to save CPU reductions.
3. **Stateless Operations:** Per-message independent compression operations (no context takeover in V1) prevent unbounded memory retention across long-lived signaling connections.

## Consequences
- **Positive:** Protects real-time media forwarding timers from scheduler starvation caused by heavy signaling decompression jobs.
