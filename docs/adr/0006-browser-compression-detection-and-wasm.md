# ADR-0006: Browser Compression Probing & Fallback Strategy

## Status
**ACCEPTED** (2026-11-20)

## Context
Browser support for MDN `CompressionStream` and `DecompressionStream` varies across browser vendors and versions for Brotli, Gzip, and Zstandard.

## Decision
1. **Runtime Probing:** Browser SDKs probe available formats at runtime via `try { new CompressionStream('deflate-raw'); ... }` and advertise only successfully tested formats.
2. **Mandatory Uncompressed Fallback:** `NONE` (algorithm ID 0) is mandatory for all clients. If a browser does not support native Zstd or Brotli, negotiation transparently falls back to `GZIP` or `NONE`.
3. **No Untrusted WASM Polyfills in V1:** Defer shipping heavy WebAssembly decompressors to client bundles in V1 to keep SDK payload sizes minimal.

## Consequences
- **Positive:** Robust cross-browser compatibility without bloatware in client bundles.
