# ADR-0011: Recording Storage & Retention Security

## Status
**ACCEPTED** (2026-11-20)

## Context
Recording requires capturing media without adding backpressure to live participants or leaking private caller audio.

## Decision
1. **Separately Supervised Consumer:** Recording is implemented as an independent DownTrack subscriber process (`EVoiceKit.Media.RecordingConsumer`).
2. **Asynchronous Disk/Cloud Flush:** Media chunks are buffered in bounded queues and flushed asynchronously to S3/GCS or local encrypted storage.
3. **Strict Tenant Retention:** Recording files are encrypted at rest with tenant-scoped keys and governed by tenant retention policies.

## Consequences
- **Positive:** Disk latency or S3 upload delays never stall live audio/video communication between room participants.
