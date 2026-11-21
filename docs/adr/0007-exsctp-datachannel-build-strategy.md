# ADR-0007: ExSCTP DataChannel Build & Toolchain Strategy

## Status
**ACCEPTED** (2026-11-20)

## Context
ExWebRTC supports WebRTC DataChannels through the optional dependency `ex_sctp`, which requires a native Rust compilation toolchain (`rustc`, `cargo`).

## Decision
1. **Optional Dependency:** `ex_sctp` is marked `optional: true` in `mix.exs` so audio/video SFU capabilities can compile in lightweight environments without Rust installed.
2. **Containerized Build Support:** The production `Dockerfile` build stage includes `rust` and `cargo` packages, ensuring DataChannels compile cleanly in production releases.

## Consequences
- **Positive:** Fast development iteration on core audio/signaling while maintaining full DataChannel capability in containerized releases.
