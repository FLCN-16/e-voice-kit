# ADR-0010: Video Codec Roadmap & Licensing Boundaries

## Status
**ACCEPTED** (2026-11-20)

## Context
Video forwarding requires clear codec priorities and licensing assessments (VP8, VP9, H.264, AV1).

## Decision
1. **Pass-Through Forwarding:** The SFU operates as a pure pass-through forwarding unit without server-side video transcoding in V1.
2. **Codec Order:** VP8 (open, royalty-free) is the primary video baseline, followed by H.264 pass-through for mobile hardware acceleration.
3. **Simulcast:** RID-based simulcast layer selection is performed by subscriber DownTracks via keyframe PLI requests.

## Consequences
- **Positive:** Low server CPU utilization; avoids expensive video transcoding NIF dependencies.
