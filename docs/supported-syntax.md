# Supported Syntax Source of Truth

The authoritative feature/support matrix now lives in:

- `tests/harness/capabilities.zig`
  - `Capability`: canonical capability keys with per-entry doc comments.
  - `CapBackendMapEntry` + `cap_backend_map`: backend support per capability.

This replaces the manually maintained table in this document.
