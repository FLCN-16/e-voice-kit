# ADR-0013: Tenant Resource Quotas & Abuse Controls

## Status
**ACCEPTED** (2026-11-20)

## Context
Multi-tenant media servers must protect against resource exhaustion attacks (connection floods, oversized SDPs, decompression bombs, and excessive track publications).

## Decision
1. **Default Quotas:**
   - Max participants per room: 100 (configurable per tenant).
   - Max published tracks per participant: 10.
   - Max wire payload size: 2 MiB.
   - Max decompressed plain payload size: 2 MiB.
   - Max decompression expansion ratio: 15:1.
2. **Rate Limiting:** Rate limit SDP renegotiation requests, ICE restart attempts, and join requests.
3. **Immediate Dropping:** Malformed envelopes or decompression breaches immediately terminate the offending session without affecting other participants.

## Consequences
- **Positive:** Guarantees predictable server memory and CPU utilization under adversarial or buggy client behavior.
