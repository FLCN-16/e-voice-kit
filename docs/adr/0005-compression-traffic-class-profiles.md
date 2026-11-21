# ADR-0005: Compression Traffic-Class Profiles vs Directional Baseline

## Status
**ACCEPTED** (2026-11-20)

## Context
Different message types have different size, latency, and compression ratio characteristics (e.g. 50-byte ping/mute events vs 50 KiB room roster snapshots).

## Decision
1. **Directional Baseline in V1:** Compression algorithms are negotiated per direction (`client_to_server` and `server_to_client`).
2. **Dynamic Payload Thresholds:** Individual messages smaller than 256 bytes bypass compression (`NONE`), avoiding negative compression (where header overhead exceeds savings).
3. **Traffic-Class Profiles in V2:** Granular per-class profiles (interactive control vs bulk sync) are deferred until empirical microbenchmarks on target device profiles are completed.

## Consequences
- **Positive:** Minimizes CPU overhead and BEAM reduction consumption for small real-time control events while compressing large metadata frames.
